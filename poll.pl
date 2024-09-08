#!/usr/bin/env perl

use Mojo::Base -strict, -signatures;
use RxPerl::IOAsync ':all';
use IO::Async::Loop;
use Mojo::File qw(path);
use Mojo::Collection qw(c);
use Mojo::Log;
use Git::Repository;
use Getopt::Long;
use IO::Async::Process;
use DDP;

my @opts = qw( repo=s@ verbose  poll=i);
my %globals;
$globals{log} = Mojo::Log->new;

my $loop = IO::Async::Loop->new;
RxPerl::IOAsync::set_loop($loop);

sub setup {
  GetOptions (\%globals, @opts) or die "Error parsing options";
  $globals{repo} = $globals{repo}->@* ? c($globals{repo}->@*) : c($ENV{PWD} || '.');
  $globals{poll} //= 60; # one minute polling
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

sub update_repo ($git){
  $globals{log}->info("fetching updates for " . $git->git_dir);
  $git->run('fetch');
  my $status = $git->run('status');

  if ($status =~ /branch.*behind/) {
    $globals{log}->info(
      sprintf ("repository %s needs update", $git->git_dir)
    );
    $git->run('pull');
  }
}

sub pull_tasker ($git) {

  $globals{log}->info(
    sprintf ("created observer for %s", $git->git_dir)
  );

  return {
    next      => sub { $loop->add(create_subprocess(sub { update_repo($git) }, $git->git_dir)) },
    error     => sub ($err) { $globals{log}->error("Error in stream: $err") },
    complete  => sub { $globals{log}->info( 'Great success') },
  };
}

sub create_subprocess($cb, $repo) {
  $globals{log}->info("generating subprocess for $repo");

  return IO::Async::Process->new(
    code => $cb,
    # stdout => {
    #   on_read => sub {
    #     my ($stream, $buffref) = @_;
    #     while( $$buffref =~ s/^(.*)\n// ) {
    #       $globals{log}->info(
    #         sprintf("output $$: %s ", $1)
    #       );
    #     }
    #     return 0;
    #   },
    # },
    on_exception => sub ($exception, $errno, $exitcode) {
      $globals{log}->error("Exception $exception, happed $errno, resulted $exitcode as exit code");
    },
    on_finish => sub {
      $globals{log}->info("($$)finished checking for $repo");
    },
  );
}

sub setup_polling {
  my $sources = $globals{git}->map(
    sub { rx_timer(0,$globals{poll})->subscribe(pull_tasker($_)) }
  );
  return $sources;
}

setup;
my $sources = setup_polling;
$loop->run;
