#!/usr/bin/perl
##############################################################################
#
#  Data::Tools test suite -- Data::Tools::Process::ForkPool
#  Copyright (c) 2026 Vladi Belperchinov-Shabanski "Cade"
#        <cade@noxrun.com>
#  http://cade.noxrun.com/
#
#  GPL
#
##############################################################################
use strict;
use lib 'lib', '../lib';
use Test::More;

use POSIX qw( WNOHANG );
use Time::HiRes qw( time sleep );
use Net::Tools::Socket::Pair;
use Data::Tools::Process::ForkPool;

ok( defined $Data::Tools::Process::ForkPool::VERSION, 'Data::Tools::Process::ForkPool loaded' );

my $MAIN_PID  = $$;
my $MAIN_PGRP = getpgrp( 0 );

# test worker: reports idle, then follows supervisor's commands
sub worker
{
  my $tag = shift;

  $SIG{ 'TERM' } = 'DEFAULT'; # do not inherit supervisor's handlers
  $SIG{ 'INT'  } = 'DEFAULT';

  fpool_iam_idle();
  while( 4 )
    {
    my $msg;
    my $res = fpool_recv_super( \$msg );
    return 0 unless defined $res; # supervisor gone
    if( ! $res ) # nothing yet
      {
      sleep( 0.02 );
      next;
      }
    if(    $msg eq 'BUSY'  ) { fpool_iam_busy() }
    elsif( $msg eq 'IDLE'  ) { fpool_iam_idle() }
    elsif( $msg eq 'PING'  ) { fpool_send_super( "PONG $tag $$ " . getpgrp( 0 ) ) }
    elsif( $msg eq 'SPAM'  ) { fpool_send_super( "m$_" ) for 1 .. 5 }
    elsif( $msg eq 'QUIT'  ) { return 7 }
    elsif( $msg eq 'DIE'   ) { die "worker died (expected by the test)\n" }
    }
}

# polls $code until true or timeout
sub wait_until
{
  my $code = shift;
  my $to   = shift || 5;

  my $xt = time() + $to;
  while( time() < $xt )
    {
    return 1 if $code->();
    sleep( 0.05 );
    }
  return $code->() ? 1 : 0;
}

sub alive_count
{
  return scalar grep { kill( 0, $_ ) } @_;
}

# pids from fpool_stats() text
sub stats_pids
{
  my $pool = shift;
  return map { /^\s+(\d+) => [*-]$/ ? $1 : () } split /\n/, ( fpool_stats( $pool ) // '' );
}

sub recv_one
{
  my $pool = shift;
  my $pid  = shift;
  my $data = shift;
  return wait_until( sub { fpool_update_state( $pool ); fpool_recv_from( $pool, $pid, $data ) } );
}

# stop all of pool and reap them
sub stop_pool
{
  my $pool = shift;
  fpool_stop_all( $pool );
  return wait_until( sub { fpool_wait_all( $pool ); ! fpool_count( $pool ) } );
}

##############################################################################
# arguments and unknown pools
##############################################################################

is( fpool_manage( 'T1', 'worker', 1, 1, 1 ), undef, 'fpool_manage() with non-code sub returns undef' );
is( fpool_count( 'NOPE' ),         undef, 'fpool_count() of unknown pool is undef' );
is( fpool_busy_count( 'NOPE' ),    undef, 'fpool_busy_count() of unknown pool is undef' );
is( fpool_stats( 'NOPE' ),         undef, 'fpool_stats() of unknown pool is undef' );
is( fpool_wait_all( 'NOPE' ),      undef, 'fpool_wait_all() of unknown pool is undef' );
is( fpool_update_state( 'NOPE' ),  undef, 'fpool_update_state() of unknown pool is undef' );
is( fpool_send_to( 'NOPE', 1, 'x' ), undef, 'fpool_send_to() of unknown pool is undef' );
is( fpool_send_super( 'x' ),       undef, 'fpool_send_super() in the supervisor is undef' );

  {
  my $self_term = 0;
  local $SIG{ 'TERM' } = sub { $self_term++ };
  is( fpool_stop_all( 'NOPE' ), undef, 'fpool_stop_all() of unknown pool is undef' );
  sleep( 0.1 );
  is( $self_term, 0, 'fpool_stop_all() of unknown pool does not signal the supervisor' );
  }

# fpool_fork_one() creates an unknown pool, fpool_wait_one() returns the
# raw wait status as 4th value
  {
  my $sup_pid = $$;
  my $apid = fpool_fork_one( 'AUTO', sub { 3 } );
  ok( $apid > 0, 'fpool_fork_one() creates an unknown pool' );
  my @w;
  ok( wait_until( sub { @w = fpool_wait_one( 'AUTO' ); @w } ), 'fpool_wait_one() reaps the auto pool process' );
  is_deeply( \@w, [ $apid, 3, 0, 3 << 8 ], 'fpool_wait_one() returns ( pid, exit, signal, status )' );
  is( $$, $sup_pid, 'auto pool process never returns into the supervisor code' );
  }

##############################################################################
# filling up to min, process group
##############################################################################

my $P = 'test'; # lowercase, pool names are case insensitive

is( fpool_manage( $P, \&worker, 3, 6, 2, 'A' ), 3, 'fpool_manage() starts min processes (min > step)' );
is( fpool_count( 'TEST' ), 3, 'fpool_count() sees min processes, name is case insensitive' );
my @pids = stats_pids( $P );
is( scalar @pids, 3, 'fpool_stats() lists all processes' );

ok( wait_until( sub { fpool_update_state( $P ); 1 } ), 'fpool_update_state() reads idle states' );
is( fpool_busy_count( $P ), 0, 'all processes are idle' );

my $msg;
my %pgrp;
for my $pid ( @pids )
  {
  fpool_send_to( $P, $pid, 'PING' );
  ok( recv_one( $P, $pid, \$msg ), "fpool_recv_from() gets reply from $pid" );
  my ( $tag, $rpid, $rpgrp ) = $msg =~ /^PONG (\S+) (\d+) (\d+)$/;
  is( $rpid, $pid, 'reply is from the right process' );
  is( $tag, 'A', 'extra fpool_manage() args are passed to the forked sub' );
  $pgrp{ $rpgrp }++;
  }
is( scalar keys %pgrp, 1, 'all pool processes are in one process group' );
my ( $pool_pgrp ) = keys %pgrp;
isnt( $pool_pgrp, $MAIN_PGRP, 'pool process group is not the supervisor one' );
is( $pool_pgrp, $pids[ 0 ], 'pool process group is the first forked pid' );

is( fpool_manage( $P, \&worker, 3, 6, 2, 'A' ), 0, 'fpool_manage() does not grow when not all are busy' );

##############################################################################
# growing when all busy, max + step - 1 overflow
##############################################################################

fpool_send_to( $P, $_, 'BUSY' ) for stats_pids( $P );
ok( wait_until( sub { fpool_update_state( $P ) == 3 } ), 'all 3 busy' );

is( fpool_manage( $P, \&worker, 3, 6, 2, 'A' ), 2, 'fpool_manage() grows by step when all are busy' );
is( fpool_count( $P ), 5, 'fpool_count() after growing' );

my $stats = fpool_stats( $P );
like( $stats, qr/^POOL \[TEST\] busy \[3\] forks \[5\]$/m, 'fpool_stats() header' );
is( scalar( () = $stats =~ /^  \d+ => \*$/mg ), 3, 'fpool_stats() lists 3 busy' );
is( scalar( () = $stats =~ /^  \d+ => -$/mg ), 2, 'fpool_stats() lists 2 idle' );

fpool_send_to( $P, $_, 'BUSY' ) for stats_pids( $P );
ok( wait_until( sub { fpool_update_state( $P ) == 5 } ), 'all 5 busy' );
is( fpool_manage( $P, \&worker, 3, 6, 2, 'A' ), 2, 'fpool_manage() grows by step below max' );
is( fpool_count( $P ), 7, 'pool may overflow up to max + step - 1' );

fpool_send_to( $P, $_, 'BUSY' ) for stats_pids( $P );
ok( wait_until( sub { fpool_update_state( $P ) == 7 } ), 'all 7 busy' );
is( fpool_manage( $P, \&worker, 3, 6, 2, 'A' ), 0, 'fpool_manage() does not grow at or above max' );

fpool_send_to( $P, $_, 'IDLE' ) for stats_pids( $P );
ok( wait_until( sub { fpool_update_state( $P ) == 0 } ), 'all idle again' );

##############################################################################
# messages and queue limit
##############################################################################

my $pid0 = ( stats_pids( $P ) )[ 0 ];
is( fpool_recv_from( $P, $pid0, \$msg ), 0, 'fpool_recv_from() with empty queue is 0' );
is( fpool_recv_from( $P, 1, \$msg ),     undef, 'fpool_recv_from() of unknown pid is undef' );
is( fpool_send_to( $P, 1, 'PING' ),      undef, 'fpool_send_to() of unknown pid is undef' );

  {
  local $Data::Tools::Process::ForkPool::MSG_QUEUE_MAX = 3;
  fpool_send_to( $P, $pid0, 'SPAM' );
  fpool_send_to( $P, $pid0, 'BUSY' );
  ok( wait_until( sub { fpool_update_state( $P ) == 1 } ), 'state message after spam is applied' );
  my @got;
  push @got, $msg while fpool_recv_from( $P, $pid0, \$msg );
  is_deeply( \@got, [ qw( m3 m4 m5 ) ], '$MSG_QUEUE_MAX keeps the newest messages' );
  fpool_send_to( $P, $pid0, 'IDLE' );
  ok( wait_until( sub { fpool_update_state( $P ) == 0 } ), 'idle again' );
  }

  {
  fpool_send_to( $P, $pid0, 'SPAM' );
  my @got;
  wait_until( sub { fpool_update_state( $P ); push @got, $msg while fpool_recv_from( $P, $pid0, \$msg ); @got >= 5 } );
  is_deeply( \@got, [ qw( m1 m2 m3 m4 m5 ) ], 'no queue limit by default' );
  }

##############################################################################
# stop all
##############################################################################

my @ppids = stats_pids( $P );
ok( fpool_stop_all( $P ) > 0, 'fpool_stop_all() signals the pool' );
ok( stop_pool( $P ), 'fpool_wait_all() reaps all stopped processes' );
is( fpool_count( $P ), 0, 'pool is empty' );
is( alive_count( @ppids ), 0, 'no stopped process is alive' );

  {
  my $self_term = 0;
  local $SIG{ 'TERM' } = sub { $self_term++ };
  is( fpool_stop_all( $P ), undef, 'fpool_stop_all() of empty pool is undef' );
  sleep( 0.1 );
  is( $self_term, 0, 'fpool_stop_all() of empty pool does not signal the supervisor' );
  }

##############################################################################
# exit codes, dying sub, busy count after reap
##############################################################################

my $X = 'EXITS';
is( fpool_manage( $X, \&worker, 3, 3, 1, 'X' ), 3, 'started 3 processes' );
my ( $xq, $xd, $xk ) = stats_pids( $X );

fpool_send_to( $X, $xq, 'BUSY' );
ok( wait_until( sub { fpool_update_state( $X ) == 1 } ), 'one busy' );

my $main_pid = $$;
fpool_send_to( $X, $xq, 'QUIT' );
fpool_send_to( $X, $xd, 'DIE'  );
kill( 'KILL', $xk );

my %exits;
ok( wait_until( sub {
                    while( 4 )
                      {
                      my ( $pid, $exit, $xsig ) = fpool_wait_one( $X );
                      last unless $pid;
                      $exits{ $pid } = [ $exit, $xsig ];
                      }
                    ! fpool_count( $X );
                    } ),
    'fpool_wait_one() reaps all 3' );

is( scalar( my @r = fpool_wait_one( $X ) ),      0, 'fpool_wait_one() of empty pool returns empty list' );
is( scalar( my @u = fpool_wait_one( 'NOPE' ) ),  0, 'fpool_wait_one() of unknown pool returns empty list' );
is( scalar( fpool_wait_one( $X ) ),          undef, 'fpool_wait_one() of empty pool returns undef in scalar context' );
is( $$, $main_pid, 'forked processes never return into the supervisor code' );
is_deeply( $exits{ $xq }, [ 7,   0 ], 'fpool_wait_one() returns sub return value as exit code' );
is_deeply( $exits{ $xd }, [ 255, 0 ], 'fpool_wait_one() returns 255 when sub dies' );
is_deeply( $exits{ $xk }, [ 0,   9 ], 'fpool_wait_one() returns the exit signal' );
is( fpool_busy_count( $X ), 0, 'busy count drops when a busy process is reaped' );
like( fpool_stats( $X ), qr/^POOL \[EXITS\] busy \[0\] forks \[0\]$/m, 'fpool_stats() of empty pool' );

##############################################################################
# min 0, fpool_fork_one()
##############################################################################

my $Z = 'ZERO';
is( fpool_manage( $Z, \&worker, 0, 4, 2, 'Z' ), 2, 'min 0: empty pool counts as all busy, step processes started' );
is( fpool_fork_one( $Z, 'worker' ), undef, 'fpool_fork_one() with non-code sub returns undef' );
my $fpid = fpool_fork_one( $Z, \&worker, 'F' );
ok( $fpid > 0, 'fpool_fork_one() starts a process in existing pool' );
is( fpool_count( $Z ), 3, 'fpool_fork_one() process is counted' );
fpool_send_to( $Z, $fpid, 'PING' );
ok( recv_one( $Z, $fpid, \$msg ), 'fpool_fork_one() process replies' );
like( $msg, qr/^PONG F $fpid \d+$/, 'fpool_fork_one() passes extra args' );
ok( stop_pool( $Z ), 'stopped' );

##############################################################################
# foreign children are not reaped by the pool
##############################################################################

my $R = 'FOREIGN';
fpool_manage( $R, \&worker, 1, 1, 1, 'R' );

my $plain = fork();
die "fork: $!\n" unless defined $plain;
POSIX::_exit( 5 ) unless $plain;

sleep( 0.5 );
fpool_wait_all( $R ) for 1 .. 3;
is( fpool_count( $R ), 1, 'pool process still counted' );
is( waitpid( $plain, WNOHANG ), $plain, 'pool did not reap a foreign child' );
is( $? >> 8, 5, 'foreign child exit code is intact' );
ok( stop_pool( $R ), 'stopped' );

##############################################################################

done_testing();
