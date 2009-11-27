#! /usr/bin/perl -w

use Bubba::Hotfix;

my $server = new Bubba::Hotfix({
		localpath => Bubba::Hotfix::SOCKNAME, 
		pidfile => Bubba::Hotfix::PIDFILE,
		'loop-timeout' => 30, 
	}, \@ARGV);

$server->Bind();
