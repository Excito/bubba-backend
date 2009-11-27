#!/usr/bin/perl 

use strict;
use warnings;
use Switch;

exit unless -f "/etc/bubba-notify/bubba-notify.conf";
my $conf = do "/etc/bubba-notify/bubba-notify.conf";
exit unless $conf->{enabled};

my $level="INFO";
my $message="";
my $description = "";
chomp(my $uuid=`uuidgen`);
chomp(my $date=`date`);
my $sender="RAID monitor";

my $spool = "/var/spool/bubba-notify/$uuid";

my ($event, $array, $disk ) = @ARGV;

switch( $event ) {
	case "Fail" {
		$level="ERR";
		$description="RAID disk failed";
		$message="The device $disk on array $array has failed" if $disk;
		$message="An device on array $array has failed" unless $disk;
	}
	case "FailSpare" {
		$level="ERR";
		$description="Spare RAID disk failed";
		$message="The spare device $disk on array $array has failed" if $disk;
		$message="A spare device on array $array has failed" unless $disk;
	}
	case "DegradedArray" {
		$level="ERR";
		$description="RAID Array degraded";
		$message="The array $array is degraded";
	}
	else {
		$description="RAID message";
		$message="Array $array generated event $event";
	}
}

$message =~ s/\n\n/\n.\n/sg;
$message =~ s/\n/\n /sg;
$description =~ s/\n\n/\n.\n/sg;
$description =~ s/\n/\n /sg;

open SPOOL, '>', $spool or die "couldn't open spool for writing: $!";
print SPOOL <<EOF;
UUID: $uuid
Action: MSG
Level: $level
Date: $date
Sender: $sender
Description: $description
Message: $message

EOF
close SPOOL;
