#!/usr/bin/perl
use IPC::Open3;
use CGI;

use strict;
use constant WAN_IF => "eth0";
use constant EASYFIND_CONF => "/etc/network/easyfind.conf";
use constant KEY => "/etc/network/bubbakey";
use constant BOOTARGS => "/proc/cmdline";

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
		if($file =~ m/enable\s*=\s*yes/) {
			$conf{'enable'} = "yes";
		}
		if($file =~ m/ip\s*=\s*(\d+\.\d+\.\d+\.\d+)/) {
			$conf{'ip'} = $1;
		}
		if($file =~ m/name\s*=\s*([\w\d-_]+)/) {
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
	print("Wrote config to file\n");

}

sub get_extip {
	my($wtr, $rdr, $err);
	$err = 1; # we want to dump errors here

	my $pid = open3($wtr,$rdr,$err,"wget -q -O - http://update.excito.net/extip.php");
	my $curr_ip = <$rdr>;
	my $errmsg = <$err>;
	waitpid($pid,0);

	if ($errmsg) {
		print("wget error: $errmsg\n");
		return 0;
	} else {
		return $curr_ip;	
	}
}

sub get_mac {

	my($wtr, $rdr, $err);
	$err = 1; # we want to dump errors here

	my $pid = open3($wtr,$rdr,$err,"ifconfig " . WAN_IF);
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
		print("Error, no keyfile\n");
		return 0;
	}	
}

sub update_dblink{
	my ($ip) = @_;
	my $mac;
	my $key;
	my $disable;

	$mac=get_mac();
	$key=get_key();

	if ($ip == -1) {
		$disable = "&disable=1";
	}
	my($wtr, $rdr, $err);
	$err = 1; # we want to dump errors here

	my $cmd = "wget --no-check-certificate --timeout=5 -q -O - --post-data=\"id=$mac&pwd=$key$disable\" \"https://www.bubbaserver.com/name_update.php\"";
	my $pid = open3($wtr,$rdr,$err,$cmd);
	my $errmsg = <$err>;
	my $retval = <$rdr>;
	waitpid($pid,0);
	if($retval eq "") {
		$retval = 1; # An empty string is a failure. $err always seem to be empty.
	}
	return $retval;

}

sub update_ip{

	my ($extip) = @_;
	my $err;
	my $res=0;

	if ($extip==0) {
		print("Update error\n");
		return 1;
	} else {
		#update database with new ip.
		return update_dblink($extip);
	}
}

sub print_name {

	my $p_config = shift;
	if ($$p_config{'name'}) {
		print $$p_config{'name'}."\n";
	} else {
		print "No name set\n";
	}
}

sub set_name {

	my $p_config = shift;
	my $key=get_key();
	my $mac=get_mac();
	my $name = $ARGV[1];
	my $res;
	my $success = 0;

	my($wtr, $rdr, $err);
	$err = 1; # we want to dump errors here

	#
	#if there is no name in the config file, check if there is something registered on the server.
	if(!$$p_config{name}) {
		print "DB-name: ";
		my $db_name = print_db_name();
		if($db_name =~ m/$name/i) {
			# The new name is already registerd and should be treated as a succussful call.
			$success = 1;
			$name = $db_name;
		}
	}
	if(!$success) {	# php already checks that the name does not match the name in config.

		my $cmd = "wget --no-check-certificate --timeout=2 -q -O - --post-data=\"id=$mac&pwd=$key&setname=$name\" \"https://www.bubbaserver.com/name_update.php\"";
		#print "$cmd\n";
		my $pid = open3($wtr,$rdr,$err,$cmd);
		my $errmsg = <$err>;
		my @retval = <$rdr>;
		waitpid($pid,0);
		my $response = join("\n",@retval);
		if($response =~ /Name updated/) {
			$success = 1;
		}
	}

	if($success) {
		$$p_config{'name'} = $name;
		$$p_config{'enable'} = "yes";
		print "Name updated\n";
		$res = 1;		
	}	else {
		print "Name not available\n";
		$res = 0;
	}
	return $res;
}

sub print_db_name {

	my $p_config = shift;
	my $key=get_key();
	my $mac=get_mac();

	my($wtr, $rdr, $err);
	my $cmd = "wget --no-check-certificate --timeout=2 -q -O - --post-data=\"id=$mac&pwd=$key&getname=1\" \"https://www.bubbaserver.com/name_update.php\"";
	my $pid = open3($wtr,$rdr,$err,$cmd);
	my $errmsg = <$err>;
	my @retval = <$rdr>;
	my $response = join("\n",@retval);
	waitpid($pid,0);
	if($response =~ /name\s*=\s*(\w+)/) {
		print "$1\n";
		$$p_config{name} = $1;
	}
	return $1;
}
##### start code #####

my $extip;
my %config = read_config();
my $cmd = $ARGV[0];

if ($cmd) {
	if ($cmd eq "getname") {
		if($config{name}) {
			print_name(\%config);
		} else {
			print_db_name(\%config);
			if($config{name}) {
				# Name was found on server but not in config file.
				write_config(\%config);
			}
		}
	} elsif ($cmd eq "setname") {
		if(set_name(\%config)) {
			$extip = get_extip();
			if(update_ip($extip)) {
				$config{'ip'} = $extip;
			}
			write_config(\%config);
		} 
	} elsif ($cmd eq "disable") {
		if(update_ip(-1)) {
			$config{'ip'} = "";
			$config{'enable'} = "no";
		}
		write_config(\%config);

	} elsif ($cmd eq "enable") {
		$extip = get_extip();
		if(update_ip($extip) == 0) {
			$config{'ip'} = $extip;
			$config{'enable'} = "yes";
		}
		write_config(\%config);

	} else {
		print "Unknown parameter\n";
		exit 0; # wrong parameter
	}
} else {	
	if($config{'enable'}) { # only run updates if enabled.
		$extip = get_extip();
		if($config{'ip'}) {
			if($config{'ip'} eq $extip) {
				#do nothing.
				exit 1;
			} else {
				print("IP has changed, updating.\n");
				if(update_ip($extip) ne "0") {
					print "Error updating IP on server.\n";
				} else {
					print "IP on server updated.\n";
					$config{'ip'} = $extip;
					write_config(\%config);
				}
			}
		} else { # no external IP file found.
			print "No extip\n";
			update_ip($extip);
			$config{'ip'} = $extip;
			write_config(\%config);
		}
	} else {
		print "Easyfind not enabled.\n";
	}	
	exit 1;
}
