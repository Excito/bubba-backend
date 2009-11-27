#! /usr/bin/perl -w

use Bubba::Apt;

my $server = new Bubba::Apt({
		localpath => Bubba::Apt::SOCKNAME, 
		pidfile => Bubba::Apt::PIDFILE,
		'loop-timeout' => 30, 
	}, \@ARGV);

$server->Bind();
