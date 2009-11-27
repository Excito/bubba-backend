#! /usr/bin/perl -w

use strict;

use Socket;
use POSIX;
use JSON;

my $from_js;
my $to_js;
if($JSON::VERSION<2){
	$from_js=\&jsonToObj;
	$to_js=\&objToJson;
}else{
	$from_js=\&from_json;
	$to_js=\&to_json;
}

use constant SOCKNAME	=> '/tmp/bupdater';
use constant SERVER		=> '/usr/lib/web-admin/updatebackend.pl';
#use constant SERVER		=> './updatebackend.pl';

my $debug=0;

sub start_server{
	print "Spawning new server\n" if $debug;	
	system(SERVER);
}

sub do_connect{
	my $sockpath=shift;
	my  $sock;
	socket($sock,PF_UNIX, SOCK_STREAM, 0);
	if(connect($sock, sockaddr_un($sockpath))){
		my $old_fd = select($sock);
		$|=1;
		select($old_fd);
		return $sock;
	}else{
		return 0;
	}
}

sub update_sources{
	my $sock=shift;
	my $line;
	my $res=0;
	print "Update sources" if $debug;
	syswrite $sock, "{\"action\":\"update_sources\"}\n";

	sysread $sock,$line,4000;
	print"Line[$line]\n" if $debug;
	my $ref;
    eval{
            $ref = $from_js->($line);
    };
    if(!$@) {
            print "Eval succeded\n" if $debug;
            if(exists $$ref{'result'}){
            	my $res=$$ref{'result'};
            	print "Result: $res\n" if $debug;
            }else{
            	print "No result $line\n" if $debug;
				$res=1;
            }
    }else{
    	print "Failed to eval response\n" if $debug;
    	$res=1;
    }

	return $res;	
}

sub check_updates{
	my $sock=shift;
	my $line;
	my $res=0;
	
	print "Check Updates\n" if $debug;
	syswrite $sock, "{\"action\":\"check_updates\"}\n";

	sysread $sock,$line,4000;
	print"Line[$line]\n" if $debug;
	my $ref;
    eval{
            $ref = $from_js->($line);
    };
    if(!$@) {
            print "Eval succeded\n" if $debug;
            if(exists $$ref{'result'}){
            	my $res=$$ref{'result'};
            	print "Result: $res\n" if $debug;
            	if(exists $$ref{'updates'}){
            		my $ups=join " ",@{$$ref{'updates'}};
            		print "$ups\n";
            	}else{
            		$res=1;
            	}
            }else{
            	print "No result $line\n" if $debug;
            	$res=1;
            }
    }else{
    	print "Failed to eval response\n" if $debug;
    	$res=1;
    }

	return $res;	

}

sub update_packages{
	my $sock=shift;
	my $line;
	my $res=0;
	print "Update packages" if $debug;
	syswrite $sock, "{\"action\":\"update_packages\"}\n";

	sysread $sock,$line,4000;
	print"Line[$line]\n" if $debug;
	my $ref;
    eval{
            $ref = $from_js->($line);
    };
    if(!$@) {
            print "Eval succeded\n" if $debug;
            if(exists $$ref{'result'}){
            	my $res=$$ref{'result'};
            	print "Result: $res\n" if $debug;
            }else{
            	print "No result $line\n" if $debug;
            	$res=1;
            }
    }else{
    	print "Failed to eval response\n" if $debug;
    	$res=1;
    }

	return $res;
}


# Hash with all commands
# Key 	- name to use when called
# value	- function to be called and number of arguments
my %commands=(
	"update_sources"	=> [\&update_sources ,0],
	"check_updates"		=> [\&check_updates ,0],
	"update_packages"	=> [\&update_packages ,0],
);

if ((scalar(@ARGV))==0) {
   die "Not enough arguments";
}

my $args=scalar @ARGV-1;
my $cmd=$ARGV[0];

if($commands{$cmd} && $commands{$cmd}[1]==$args){

	my $sock=do_connect(SOCKNAME);

	if(!$sock){
		start_server();
		$sock=do_connect(SOCKNAME);
		if(!$sock){
			die "Could not connect to server";
		}
	}

	$commands{$cmd}[0]->(($sock,@ARGV[1..$args]))==0 or exit 1;
	
	close $sock;
}else{
	if(!$commands{$cmd}){
		die "Command $cmd not found";
	}else{
		die "Invalid parametercount";
	}
}

