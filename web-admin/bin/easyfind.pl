#!/usr/bin/perl

eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell
use IPC::Open3;
use CGI;
use JSON;

use strict;
use constant WAN_IF => "eth0";
use constant EASYFIND_CONF => "/etc/network/easyfind.conf";
use constant KEY => "/etc/network/bubbakey";
use constant BOOTARGS => "/proc/cmdline";

sub decode_response {
	my $response = shift;
	my %resp;
	my $data;

 	if ($response->is_success) {
 		my $content = $response->decoded_content;
 		$content =~ /(\{.*\})/;
 		eval {
	 		$data = decode_json($1);
	    	%resp = %$data;
 			1;
 		} or do {
	    	$resp{'error'} = "true";
	    	$resp{'msg'} = "Caught JSON error, failed to decode server answer";
	    	return %resp;
 		};
 		
 	} else {
    	$resp{'error'} = "true";
    	$resp{'msg'} = "Failed to connect to database server";
    	print STDERR $resp{'msg'}; 
 	}
 	return %resp;
}

sub parse_boot{
	my $res={};

	open INFILE, "< " . BOOTARGS or die "Can't open file: $!";
	my @lines = <INFILE>;
	close INFILE;
	chomp(@lines);
	my @args=split(/ /,$lines[0]);
	foreach my $val (@args){
		if($val =~ /^(\w*)=(.*)/){
			$res->{$1}=$2;
		}else{
			$res->{$val}=$val;
		}
	}
	return $res;
}

sub read_config() {

	my @data;
	my %conf;
	if(-e EASYFIND_CONF) {
		open INFILE, "< " . EASYFIND_CONF or die "Can't open ".EASYFIND_CONF." : $!";
		@data = <INFILE>;
		close INFILE;
		my $file=join("\n",@data);
		if($file =~ m/enable\s*=\s*(True|true|yes|on|1)/) {
			$conf{'enable'} = "yes";
		}
		if($file =~ m/ip\s*=\s*(\d+\.\d+\.\d+\.\d+)/) {
			$conf{'ip'} = $1;
		}
		if($file =~ m/name\s*=\s*([\w\d\-_\.]+)/) {
			$conf{'name'} = $1;
		}
	}
	return %conf;	

}

sub write_config {
	## takes a reference (pointer) to config as argument.
	my $p_config =shift;
	open INFILE, "> ". EASYFIND_CONF or die "Can't open ". EASYFIND_CONF ." : $!";
	for my $key (sort keys %$p_config) {
		print INFILE "$key = $$p_config{$key}\n";
	} 
	close INFILE;
	print STDERR ("Wrote config to file\n");

}

sub get_extip {
	use LWP::Simple;
	my $url = "https://easyfind.excito.org/extip.php"; 
	my $response = get($url);
	
    if ($response) {
        return $response;
    } else {
        print STDERR "Failed to get external ip";
        return 0;
    }
}

sub get_mac {

	my($wtr, $rdr, $err);
	$err = 1; # we want to dump errors here

	my $pid = open3($wtr,$rdr,$err,"/sbin/ifconfig " . WAN_IF);
	my @if_a = <$rdr>;
	my $errmsg = <$err>;
	waitpid($pid,0);

	chomp(@if_a);
	my $if = join("\n",@if_a);
	$if=~ /HWaddr ([\d,a-f,A-F][\d,a-f,A-F]:[\d,a-f,A-F][\d,a-f,A-F]:[\d,a-f,A-F][\d,a-f,A-F]:[\d,a-f,A-F][\d,a-f,A-F]:[\d,a-f,A-F][\d,a-f,A-F]:[\d,a-f,A-F][\d,a-f,A-F])/;
	my $mac = $1;
	if (!$mac) {
		return 0;
	} else {
		return $mac;
	}
}

sub get_key{
	my $key;
	my @a_key;

	my $ba = parse_boot();

	if($$ba{"key"}){	
		return CGI::escape($$ba{"key"});
		return ($$ba{"key"});
	}elsif(-e KEY){
		open INFILE, "< ".KEY or die "Can't open ".KEY." : $!";
		@a_key = <INFILE>;
		close INFILE;
		$key = @a_key[0];
		$key=~s/\s//g;
		return $key;
	} else {
		print STDERR ("Error, no keyfile\n");
		return 0;
	}	
}

sub print_name {

	my $p_config = shift;
	my %resp;
	if ($$p_config{'ip'}) {
		$resp{'ip'} = $$p_config{'ip'};
	}
	if ($$p_config{'name'}) {
		$resp{'name'} = $$p_config{'name'};
		$resp{'error'} = "false";
	} else {
		$resp{'msg'} = "No name set";
		$resp{'error'} = "true";
		print STDERR "(print_name): No name set\n";
	}
	return %resp;
}

sub set_name {
	use URI::Escape;
	require LWP::UserAgent;
	
	my $key=get_key();
	my $mac=get_mac();
	my ($name) = @_;
	
	my $ua = LWP::UserAgent->new;
 	$ua->timeout(2);
 	
 	# set name on server.
	my $response = $ua->post('https://easyfind.excito.org/',
		[ 
			'key' => get_key(),
			'mac0' => get_mac(),
			'newname' => uri_escape($name),
			'oldname' => "",
			
		]
	);
 
 	return decode_response($response);
}

sub print_db_name {
	require LWP::UserAgent;
	
	my $ua = LWP::UserAgent->new;
 	$ua->timeout(2);
 	
 	# get record data from server.
	my $response = $ua->post('https://easyfind.excito.org/',
		[ 
			'key' => get_key(),
			'mac0' => get_mac(),
		]
	);
 
 	return decode_response($response);
}

##### start code #####

my $extip;
my %config = read_config();
my $cmd = $ARGV[0];
my %response;
if ($cmd) {
	if ($cmd eq "getname") {
		if($config{'enable'}) {
			if($config{name}) {
				%response=print_name(\%config);
			} else {				
				%response = print_db_name();
				if($response{'error'} eq "false") {
					$config{name} = $response{'record'}{'name'};
					$config{ip} = $response{'record'}{'content'};
					write_config(\%config);	
				} else {
					#server returned failure
					print STDERR $response{'msg'},"\n";
				}
				
			}
		} else {
			# not enabled
			$response{'error'} = 'false';
			$response{'msg'} = 'Not enabled';
			$response{'name'} = '';
		}
	} elsif ( $cmd eq "setname" ) {
		%response = set_name($ARGV[1]);
		if($response{'error'} eq "false") {
			$config{name} = $response{'record'}{'name'};
			$config{ip} = $response{'record'}{'content'};
			$config{'enable'} = "yes";
			write_config(\%config);	
		} else {
			#server returned failure
			print STDERR $response{'msg'},"\n";
		}
	} elsif ($cmd eq "disable") {
		%response = set_name("");
		if($response{'error'} eq "false") {
			$config{name} = "";
			$config{ip} = "";
			$config{'enable'} = "no";
			write_config(\%config);	
		} else {
			#server returned failure
			print STDERR $response{'msg'},"\n";
		}
	} else {
		print "Unknown parameter\n";
		exit 1; # wrong parameter
	}
} else {	
	if($config{'enable'}) { # only run updates if enabled.
		%response = print_db_name();
		$extip = $response{'record'}{'content'};
		if($config{'ip'} ne $extip) {
			print STDERR "Updating IP on file.\n";
			$config{'ip'} = $extip;
			write_config(\%config);
		}
	} else {
		print STDERR "Easyfind not enabled.\n";
		$response{'error'} = 'true';
		$response{'msg'} = 'Easyfind not enabled.';
	}
}
print encode_json(\%response),"\n";	
exit 0;
