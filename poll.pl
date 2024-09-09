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
  # enforce a flush of the output for git commands
  $ENV{GIT_FLUSH} = 1;
}

# read options and create git repository objects
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

# run the git command and collect data
sub run_git_cmd($cmd, $git, $opts = undef) {
  $globals{log}->info(
    sprintf ("git %s on %s repo", $cmd, $git->git_dir)
  ) if $globals{verbose};
  my $data = { $cmd => { delta => time } };
  my $git_cmd = $git->command( $opts ? ($cmd => @$opts) : $cmd );
  my @out = $git_cmd->stdout->getlines;
  my @err = $git_cmd->stderr->getlines;
  $git_cmd->close;
  $data->{$cmd}{delta} -= time;
  $data->{$cmd}{delta} *= -1;
  $data->{$cmd}{output} = join "\n", @out;
  $data->{$cmd}{stderr} = join "\n", @err;
  $data->{$cmd}{pid} = $$;
  $data->{$cmd}{opts} = $opts;
  $data->{$cmd}{repo} = $git->git_dir;
  $globals{log}->info( Dump($data) ) if $globals{verbose};

  return $data;
}

# save statistic of operation time to complete
sub stats_data ($file, $data){
  my $handler = $file->open('>>');
  my ($cmd) = keys %$data;
  my $cmd_data = $data->{$cmd};
  $handler->write(join( ",", $cmd, map {$cmd_data->{$_}} qw(delta) ) . "\n");
  $handler->close;
}

# the main function to update (pull changes) for outdate repository
sub update_repo ($git) {
  $globals{log}->info("fetching updates for " . $git->git_dir) if $globals{verbose};
  my $repo = path($git->git_dir)->to_array->[-2];
  my $data_file = path("/tmp/data_$repo.csv");

  my $fetch = run_git_cmd('fetch', $git);
  stats_data($data_file, $fetch);

  my $status = run_git_cmd('status', $git);
  stats_data($data_file, $status);

  if ($status->{status}{output} =~ /branch.*behind/si) {
    $globals{log}->info(
      sprintf ("applying changes into %s", $git->git_dir)
    );
    my $pull = run_git_cmd('pull', $git);
    stats_data($data_file, $pull);
  }
  return 1;
}

# create the observer for the git repositories
sub pull_tasker ($git) {
  $globals{log}->info(
    sprintf ("created observer for %s", $git->git_dir)
  );

  # a dummy process for testing purpose
  my $dummy = sub { 
    $globals{log}->info("DUMMY call to github");
    ($$ =~ m/(\d)$/);
    sleep ($1);
    $globals{log}->info("Great Success on nap $1 !");
  };

  return {
    next      => sub { create_subprocess(sub { update_repo($git) }, $git->git_dir) },
    # next      => sub { create_subprocess($dummy, $git->git_dir) },
    error     => sub ($err) { $globals{log}->error("Error in stream: $err") },
    complete  => sub { $globals{log}->info( 'Great success') },
  };
}

# make a subprocess with a timeout attached to it
sub create_subprocess($cb, $repo) {
  $globals{log}->info("generating subprocess for $repo");

  # the process attached to the callback ($cb)
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
    on_finish => sub ($self, $code){
      my $status = ( $code >> 8 );
      $globals{log}->info("finished fecth/pull for $repo with $status code");
    },
  );

  # set both in the loop: process and timeout
  $loop->add( $process );
  # the timeout
  $loop->add(
    IO::Async::Timer::Countdown->new(
      delay     => int($globals{poll} * 0.95),
      on_expire => sub { 
        if ($process->is_running) {
          $globals{log}->warn(
            sprintf ("(%d) killed process on repo: %s", $process->pid, $p)
          ) if $globals{verbose};
          $process->kill(15);
        }
      },
    )->start
  );
}

# setup the Rx component to each repository
sub setup_polling {
  # wait randomly before each git fetch/pull request
  time =~ m/^(\d).*(\d)$/;
  my $rand_start = sub { int(rand($1)) + int(rand($2)) };

  return $globals{git}->map(
    sub { rx_timer($rand_start->(),$globals{poll})->subscribe(pull_tasker($_)) }
  );
}

sub main {
  setup;
  my $sources = setup_polling; #keep observables alive
  $loop->run;
}

main();
