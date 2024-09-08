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
use YAML;
use DDP;

my @opts = qw( repo=s@ verbose  poll=i);
my %globals;
$globals{log} = Mojo::Log->new;

my $loop = IO::Async::Loop->new;
RxPerl::IOAsync::set_loop($loop);

BEGIN {
  #will force a flush of the output for git commands
  $ENV{GIT_FLUSH} = 1;
}
sub setup {
  GetOptions (\%globals, @opts) or die "Error parsing options";
  $globals{repo} //= c($ENV{PWD} || '.');
  $globals{repo} = c($globals{repo}->@*) if ref $globals{repo} eq 'ARRAY';
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

sub run_git_cmd($cmd, $git, $opts = undef) {
  $globals{log}->info(
    sprintf ("git %s on %s repo", $cmd, $git->git_dir)
  ) if $globals{verbose};
  my $data = { $cmd => { delta => time } };
  my $git_cmd = $git->command( $opts ? ($cmd => @$opts) : $cmd );
  my @out = $git_cmd->stdout->getlines;
  my @err = $git_cmd->stderr->getlines;
  $data->{$cmd}{delta} -= time;
  $data->{$cmd}{delta} *= -1;
  $data->{$cmd}{output} = join "\n", @out;
  $data->{$cmd}{stderr} = join "\n", @err;
  $data->{$cmd}{pid} = $$;
  $data->{$cmd}{opts} = $opts;
  $data->{$cmd}{repo} = $git->git_dir;
  $globals{log}->info( Dump($data) ) if $globals{verbose};

  return $data->{$cmd}{output};
}

sub update_repo ($git) {
  $globals{log}->info("fetching updates for " . $git->git_dir) if $globals{verbose};
  run_git_cmd('fetch', $git);

  my $status = run_git_cmd('status', $git);

  if ($status =~ /branch.*behind/) {
    $globals{log}->info(
      sprintf ("applying changes into %s", $git->git_dir)
    );
    run_git_cmd('pull', $git);
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
    on_exception => sub {
      my ($self, $exception, $exitcode) = @_;
      $globals{log}->error("($p)Error, $exception, failed with code $exitcode");
    },
    on_finish => sub {
      $globals{log}->info("finished fecth/pull for $repo");
    },
  );

  $loop->add( $process );
  $loop->add(
    IO::Async::Timer::Countdown->new(
      delay     => int($globals{poll} * 0.95),
      on_expire => sub { 
        if ($process->is_running) {
          $globals{log}->warn(
            sprintf ("(%d) killed fetching for %s", $process->pid, $p)
          ) if $globals{verbose};
          $process->kill(15);
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

sub main {
  setup;
  my $sources = setup_polling; #keep observables alive
  $loop->run;
}

main();
