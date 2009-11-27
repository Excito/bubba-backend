#!/usr/bin/perl 

use strict;
use warnings;


use JSON;
use Data::Dumper;
use Fcntl ':flock';
use Config::Tiny;

my $LEVELS = {
	IGN => 0, #ignored
	ERR => 1,
	WARN => 2,
	INFO => 3 
};

my $user_configs = {};
my $user_caches = {};

exit unless -f "/etc/bubba-notify/bubba-notify.conf";
my $conf = do "/etc/bubba-notify/bubba-notify.conf";
exit unless $conf->{enabled};

my $cache;
my $cache_file = '/var/cache/bubba-notify/ui';
my $LOCK = '/var/lock/bubba-notify-ui.lock';
open( LOCK, '>', $LOCK );

flock( LOCK, LOCK_EX );

if( -f $cache_file ) {
	open CACHE, '<', $cache_file;
	$cache = from_json( <CACHE>, {utf8 => 1} );
	close CACHE;
} else {
	$cache = {};
}


my $data = <STDIN>;
my $decoded = from_json( $data, {utf8 => 1} );

foreach my $entry ( @$decoded ) {

	if( exists $entry->{Reciever} ) {
		my $user = lc $entry->{Reciever};
		my $user_cache_file = "$cache_file\_$user";
		my $user_config_file = "/home/$user/.bubbacfg";

		if( ! exists $user_configs->{$user} ) {
			if( -f $user_config_file ) {
				my $cfg = Config::Tiny->read( $user_config_file );
				if( exists $cfg->{notify} ) {
					$user_configs->{$user} = $cfg->{notify};
				} else {
					next;
				}
			} else {
				next;
			}
		}

		if( ! exists $user_caches->{$user} ) {
			if( -f $user_cache_file ) {
				open CACHE, '<', $user_cache_file;
				$user_caches->{$user} = from_json( <CACHE>, {utf8 => 1} );
				close CACHE;
			} else {
				$user_caches->{$user} = {};
			}
		}

	}
	unless( exists $entry->{Action} ) {
		# required element
		next;
	}

	if( $entry->{Action} eq 'OFF' ) {
		if( exists $entry->{Reciever} ) {
			my $user = lc $entry->{Reciever};
			unlink "$cache_file\_$user";
			next;
		} else {
			unlink $cache_file;
			unlink glob "$cache_file\_*";
			exit;
		}
	}

	unless( exists $entry->{UUID} ) {
		# required element
		next;
	}

	if( $entry->{Action} eq 'ACC' ) {
		if( exists $entry->{Reciever} ) {
			my $user = lc $entry->{Reciever};
			delete 	$user_caches->{$user}->{$entry->{UUID}};
		} else {
			delete $cache->{$entry->{UUID}};
		}
		next;
	}

	unless( exists $entry->{Level} ) {
		# required element
		next;
	}

	if( $entry->{Action} eq 'MSG' ) {
		if( exists $entry->{Reciever} ) {
			my $user = lc $entry->{Reciever};
			next unless exists $user_configs->{$user}->{ui_level};
			if( $LEVELS->{$entry->{Level}} <= $user_configs->{$user}->{ui_level} ) {
				$user_caches->{$user}->{$entry->{UUID}} = $entry;
			}
		} else {
			if( $LEVELS->{$entry->{Level}} <= $conf->{ui_level} ) {
				$cache->{$entry->{UUID}} = $entry;
			}
		}
	} else {
		# unknown action
	}
}

open CACHE, '>', $cache_file;
print CACHE to_json( $cache, {utf8 => 1} );
close CACHE;

while( my( $user, $user_cache ) = each %$user_caches ) {
	my $user_cache_file = "$cache_file\_$user";
	open CACHE, '>', $user_cache_file;
	print CACHE to_json( %$user_cache, {utf8 => 1} );
	close CACHE;
}

close LOCK;
