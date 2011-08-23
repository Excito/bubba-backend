#!/usr/bin/perl -w
use ExtUtils::MakeMaker;

WriteMakefile(
	NAME            => 'Bubba',
	EXE_FILES		=> [
	'bin/adminfunctions.php',
	'bin/backend.pl',
	'bin/disk.pl',
	'bin/firewall.pl',
	'bin/easyfind.pl',
	'bin/backup.pl',
	'bin/diskdaemon.pl',
	'bin/notify-dispatcher.pl',
	'bin/notify-monitor-raid.pl',
	],
	VERSION_FROM    => 'lib/Bubba.pm'
);
