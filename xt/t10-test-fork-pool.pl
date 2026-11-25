#!/usr/bin/perl
##############################################################################
#
#  Data::Tools::Process::ForkPool manual test
#  Copyright (c) 2026 Vladi Belperchinov-Shabanski "Cade"
#        <cade@noxrun.com>
#  http://cade.noxrun.com/
#
#  GPL
#
#  keeps pool of $MIN to $MAX forked processes, growing by $STEP when all
#  are busy. each one reports busy/idle state to the supervisor every second
#  and exits after random 5-20 seconds or on INT/TERM.
#  supervisor refills the pool and prints busy count and stats every second.
#
##############################################################################
use strict;
use lib 'lib', '../lib';
use Data::Tools::Process::ForkPool;

$| = 1;

my $POOL     = 'TEST';
my $MIN      =  3;
my $MAX      = 20;
my $STEP     =  4;
my $RUN_TIME = 60; # seconds to keep refilling the pool

my $break_main_loop;

$SIG{ 'INT'  } = sub { $break_main_loop++ };
$SIG{ 'TERM' } = sub { $break_main_loop++ };

my $stop = time() + $RUN_TIME;
while( time() < $stop and ! $break_main_loop )
  {
  fpool_manage( $POOL, \&worker, $MIN, $MAX, $STEP );
  print fpool_stats( $POOL );
  sleep( 1 );
  }

print "SUPER: stopping all...\n";
fpool_stop_all( $POOL );
print "SUPER: waiting all...\n";
while( fpool_count( $POOL ) > 0 )
  {
  fpool_wait_all( $POOL );
  sleep( 1 );
  }
print "SUPER: done\n";











sub worker
{
  srand( $$ ^ time() ); # forked processes inherit parent's rand() state

  $SIG{ 'INT'  } = sub { $break_main_loop++ };
  $SIG{ 'TERM' } = sub { $break_main_loop++ };

  my $life = 5 + int( rand( 16 ) ); # 5-20 seconds
  my $end  = time() + $life;

  my $pgrp = getpgrp( 0 );


  print "             [$pgrp:$$] +++++++++++ started, will exit after $life seconds\n";

  while( time() < $end and ! $break_main_loop )
    {
    if( rand() < 0.9 )
      {
      fpool_iam_busy();
      #print "    [$$] STATE:*\n";
      }
    else
      {
      fpool_iam_idle();
      #print "    [$$] STATE:-\n";
      }
    sleep( 1 );
    }

  print "             [$pgrp:$$] -----------------------> exit\n";
  return 0;
}
