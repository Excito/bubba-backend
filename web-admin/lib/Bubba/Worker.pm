package Bubba::Worker;

my $VERISON = '1.0';
use strict;
use warnings;

use base qw(IO::Socket::UNIX);
use IO::Socket::UNIX;
use IPC::Run3;

sub new($$@) {
	my( $class, $socket, $cmd ) = @_;
	unless( system( 'pidof', $cmd->[0] ) >> 8 == 0 ) {
		my ($stdin, $stdout, $stderr );
		run3 $cmd, $stdin, \$stdout, \$stderr;
	}

	my ($self) = $class->SUPER::new( Type => SOCK_STREAM, Peer => $socket );

	$self;
}
