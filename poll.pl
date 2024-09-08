#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;
use RxPerl::IOAsync ':all';
use IO::Async::Loop;
use Mojo::File qw(path);
use Mojo::Collection qw(c);
use Mojo::Log;
use Git::Repository;
use Getopt::Long;
use IO::Async::Timer::Countdown;
use IO::Async::Process;
use DDP;

my @opts = qw( repo=s@ verbose  poll=i);
my %globals;
$globals{log} = Mojo::Log->new;

my $loop = IO::Async::Loop->new;
RxPerl::IOAsync::set_loop($loop);

sub setup {
  GetOptions (\%globals, @opts) or die "Error parsing options";
  $globals{repo} //= c($ENV{PWD} || '.');
  $globals{repo} = $globals{repo}->@* ? c($globals{repo}->@*) : c($ENV{PWD} || '.');
  $globals{poll} //= 60*60*3; # three hours
  $globals{git} = c();
  $globals{repo}->each(
    sub {
      my $repo;
      eval { $repo = Git::Repository->new( work_tree => $_ ); };
      if ($@) {
        $globals{log}->error("Error checking $_ as git repository: $@");
      } else {
        push @{$globals{git}}, $repo;
      }
    }
  );
  die "Failed to create any Git::Repository" if $globals{git}->size == 0;
  $globals{log}->info("finish setup");
}

sub update_repo ($git) {
  $globals{log}->info("fetching updates for " . $git->git_dir);
  $git->run('fetch');
  my $status = $git->run('status');

  if ($status =~ /branch.*behind/) {
    $globals{log}->info(
      sprintf ("applying changes into %s", $git->git_dir)
    );
    $git->run('pull') or die "Could not fetch $@";
  }
  return 1;
}

sub pull_tasker ($git) {

  $globals{log}->info(
    sprintf ("created observer for %s", $git->git_dir)
  );

  return {
    next      => sub { create_subprocess(sub { update_repo($git) }, $git->git_dir) },
    error     => sub ($err) { $globals{log}->error("Error in stream: $err") },
    complete  => sub { $globals{log}->info( 'Great success') },
  };
}

sub create_subprocess($cb, $repo) {
  $globals{log}->info("generating subprocess for $repo");

  my $p = path($repo);
  my $name = $p->to_array->[-2];
  my $setup = [
    stdin  => [ "open", "<",  "/dev/null" ],
    stdout => [ "open", ">>", "/tmp/$name.log" ],
    stderr => [ "open", ">>", "/tmp/updater/$name.log" ],
  ];
  my $process = IO::Async::Process->new(
    code => $cb,
    setup => $setup,
    on_exception => sub ($exception, $errno, $exitcode){
      $globals{log}->error("($p)Error, $exception, failed with code $exitcode");
    },
    on_finish => sub {
      $globals{log}->info("finished fecth/pull for $repo");
    },
  );

  $loop->add( $process );
  $loop->add(
    IO::Async::Timer::Countdown->new(
      delay => int($globals{poll} * 0.95),
      on_expire => sub { 
        if ($process->is_running) {
          $process->kill(15);
          $globals{log}->warn(
            sprintf ("(%d) killed fetching for %s", $process->pid, $p)
          );
        }
      },
    )->start
  );
}

sub setup_polling {
  return $globals{git}->map(
    sub { rx_timer(0,$globals{poll})->subscribe(pull_tasker($_)) }
  );
}

setup;
my $sources = setup_polling; #keep observables alive
$loop->run;
