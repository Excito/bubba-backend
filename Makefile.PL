#!/usr/bin/perl -w
use ExtUtils::MakeMaker;

WriteMakefile( DIR => [ 'web-admin' ] ,	INSTALLDIRS => 'vendor',
	INSTALLVENDORSCRIPT => '$(PREFIX)/lib/web-admin',
	INSTALLSITESCRIPT => '$(PREFIX)/lib/web-admin');
