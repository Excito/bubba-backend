#!/usr/bin/perl

use strict;
use warnings;

use constant BLUE => 0;
use constant RED => 1;
use constant GREEN => 2;


use JSON;
use Data::Dumper;
use Fcntl ':flock';
my $LEVELS = {
	IGN => 0, #ignored
	ERR => 1,
	WARN => 2,
	INFO => 3 
};


exit unless -f "/etc/bubba-notify/bubba-notify.conf";
my $conf = do "/etc/bubba-notify/bubba-notify.conf";
exit unless $conf->{enabled};

my $cache;
my $cache_file = '/var/cache/bubba-notify/led';
my $LOCK = '/var/lock/bubba-notify-led.lock';
open( LOCK, '>', $LOCK );

flock( LOCK, LOCK_EX );

if( -f $cache_file ) {
	$cache = do $cache_file;
} else {
	$cache = {};
}

my $data = <STDIN>;
my $decoded = from_json( $data, {utf8 => 1} );

foreach my $entry ( @$decoded ) {
	unless( exists $entry->{Action} ) {
		# required element
		next;
	}

	if( $entry->{Action} eq 'OFF' ) {
		unlink $cache_file;
		system( 'echo lit > /sys/devices/platform/bubbatwo/ledmode' );
		system( 'echo ' . BLUE . '> /sys/devices/platform/bubbatwo/color' );
		exit;
	}
	unless( exists $entry->{UUID} ) {
		# required element
		next;
	}

	if( $entry->{Action} eq 'ACC' ) {
		delete $cache->{$entry->{UUID}};
		next;
	}

	unless( exists $entry->{Level} ) {
		# required element
		next;
	}	

	if( $entry->{Action} eq 'MSG' && $LEVELS->{$entry->{Level}} <= $conf->{led_level} ) {
		$cache->{$entry->{UUID}} = 1;
	} else {
		# unknown action
	}
}

if( scalar map { $_ > 0 } values %$cache ) {
	system( 'echo 12000 > /sys/devices/platform/bubbatwo/ledfreq' );
	system( 'echo blink > /sys/devices/platform/bubbatwo/ledmode' );
	system( 'echo '. RED .' > /sys/devices/platform/bubbatwo/color' );
} else {
	system( 'echo lit > /sys/devices/platform/bubbatwo/ledmode' );
	system( 'echo ' . BLUE . ' > /sys/devices/platform/bubbatwo/color' );
}

open CACHE, '>', $cache_file;
print CACHE Dumper $cache;
close CACHE;

close LOCK;
