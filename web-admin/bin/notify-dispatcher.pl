#!/usr/bin/perl 

use strict;
use warnings;


use Fcntl ':flock';
use Bubba::Notify;

my $NOTIFIERS = '/etc/bubba-notify/enabled';
my $SPOOL = '/var/spool/bubba-notify';
my $LOCK = '/var/lock/bubba-notify.lock';

open( LOCK, '>', $LOCK );
flock( LOCK, LOCK_EX );
Bubba::Notify::loop_spool( $SPOOL, $NOTIFIERS );
close( LOCK );
