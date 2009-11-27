use strict;
use warnings;

package Bubba::Notify;
our $VERSION   = '1.00';
use AutoLoader 'AUTOLOAD';

1;

__END__

sub loop_spool {
	use Carp;

	my ($SPOOL, $NOTIFIERS ) = @_;

	croak "Spool directory $SPOOL not found!" unless -e $SPOOL;
	croak "Spool directory $SPOOL is not an directory!" unless -d $SPOOL;
	croak "Enabled notifiers directory $NOTIFIERS not found!" unless -e $NOTIFIERS;
	croak "Enabled notifiers directory $NOTIFIERS is not an directory!" unless -d $NOTIFIERS;

	foreach my $file (<$SPOOL/*>) {
		$data = parse_spool( $file );

		foreach my $notifier (<$NOTIFIERS/*>) {
			unless( -x $notifier ) {
				carp "can not execute $notifier";
				next;
			}

			notify( $data, $notifier );
		}

		unlink $file;
	}
}

sub parse_spool {
	use Parse::DebControl;

	my ($file, $NOTIFIERS) = @_;

	my $parser = new Parse::DebControl;

	my $data = $parser->parse_file( $file, { stripComments => 1 } );

	return $data;
}

sub notify {
	use JSON;

	my( $data, $notifier ) = @_;

	my $json = to_json $data, {utf8 => 1};

	open PIPE, '|-', $notifier;
	print PIPE $json;
	print PIPE "\n";
	close PIPE;
}
