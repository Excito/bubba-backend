#! /usr/bin/perl

package Bubba;
$VERSION   = '1.00';
use AutoLoader 'AUTOLOAD';

use vars qw($uid $gid);

1;
__END__

sub getusergroups{
	my ($user)=@_;
	my @gs;
	my $ret="";
	while(@gs=getgrent()){
		my ($name,$passwd,$gid,$members)=@gs;
		my @users=split(/ /,$members);
		if(@users){
			foreach(@users){
				if($_ eq $user){
					$ret.="$gid ";
				}
			}
		}
	}
	return $ret;
}

sub su{
	my($name,$group)=@_;
	my $new_uid=getpwnam($name);
	if(!defined($new_uid)){
		die "Could not get uid of user [$name]";
	}
	my $new_gid=getgrnam($group);
	if(!defined($new_gid)){
		die "Could not get gid of group [$group]";
	}
	my $groups=getusergroups($name).$new_gid;
	
	# Save original value
	$uid=$>;
	$gid=$);

	# Change identity
	$)=$groups;
	$>=$new_uid;

}


sub unsu{
	$>=$uid;
	$)=$gid;
}


#read temperature of /dev/hda
sub get_hdtemp{

	my $disk=shift;
	my $string;

	if(-x "/usr/sbin/hddtemp"){
		$string=`hddtemp $disk`;
		if($string =~ /:\s(\d\d.+C)/) {
			print "$1\n";
			return 0;
		} else {
			print "Err\n";
			return 1;
		}
	}else{
		print "N/A\n";
		return 0;
	}
}

#return system uptime
sub uptime{
        my $string=`uptime`;
	if ($string =~ /up\s+(\d+:\d+),/) {
		print "$1\n";
		return 0;
	} else {
		return 1;
	}
}

# set date and time
sub set_time{
	my ($date) = $ARGV[1];
	my ($time) = $ARGV[2];
	my ($month,$day,$cent,$year,$hour,$min,$datecode);
	#print "DATE: " . $date . " TIME: " . $time . "\n";
	$date =~ s/(\d\d)(\d\d)(\d\d)(\d\d)//;
	$month = $3;
 	$day = $4;
	$cent = $1;
	$year = $2;
	$time =~ s/(\d\d)(\d\d)//;
	#print "TIME: $time";
	$hour = $1;
	$min = $2;	
	$datecode = $month . $day . $hour . $min . $cent . $year;
	#print "DATECODE $datecode \n";
	if ($date or $time){ 
		print "Error in parsing data\n";
		return 1;
	} else {
		system("date $datecode");
	}
	#print $? ."\n";
	return $?;  
}
# remove a file or directory from the filesystem
sub rm{
   my ($file,$user) = @_;
   su($user,"users");
   system("rm", "-rf", $file);
   $ret=$?;
   unsu();
   return $ret;

}

# Change permissions
sub changemod{
   my ($dest, $mask, $user) = @_;

   my $res;
   $mask=oct($mask);

   su($user,"users");
   if(-d$dest){
      if($mask&0700){
         $mask|=0100;
      }
      if($mask&0070){
         $mask|=0010;
      }
      if($mask&0007){
         $mask|=0001;
      }
   }
  
   $res=chmod $mask, $dest;

   unsu();

   return $res==1?0:1;
}

# Create new directory
sub md{
   my ($dir, $mask ,$user) = @_;
   my $res;
   my $gid=getgrnam("users") or die "Could not get gid of group [users]";
   su($user,"users");

   my $umask=umask();
   umask(0);
   $res=mkdir($dir,$mask);
   chown(-1,$gid,$dir);
   umask($umask);
   
   unsu();

   return $res;
}

# move a file from srcfile to dstfile
# used by filemgr.php
sub mv{
  my ($srcfile,$dstfile,$user) = @_;
  my $res=0;
  
  su($user,"users");
  print("mv -f \"$srcfile\" \"$dstfile\"\n");
  system("mv","-f",$srcfile,$dstfile);
  $res=$?;
  unsu();

  if($res>0){
     return $res;
  }

  system("chown", "$user:users",$dstfile);
  return $?;

}

# Get filesize for file
sub get_filesize{
	my ($file, $user)=@_;
	su($user,"users");
	print system("stat","-c","%s",$file);
	$res=$?;
	unsu();
	return $res;
}

# Determine the filetype
# used by filemgr.php
sub get_mime{
  my ($file)=$ARGV[1]; 

  system("/usr/bin/file", "-b", "-i", $file);
  
  return $?;
}

sub sizetohuman{
	my($val)=@_;
	my $ret;

	if($val>=1024 && $val<1048576){
		$ret= sprintf("%.1fK",($val/1024));
	}elsif($val>=1048576 && $val<1073741824){
		$ret=sprintf("%.1fM",($val/1048576));
	}elsif($val>=1073741824){
		$ret=sprintf("%.1fG",($val/1073741824));
	}else{
		$ret="$val";
	}
}

sub parsefilemode{
	my($val)=@_;
	if(($val & 0140000)==0140000){ return "S";}
	if(($val & 0120000)==0120000){ return "L";}
	if(($val & 0100000)==0100000){ return "F";}
	if(($val & 0060000)==0060000){ return "B";}
	if(($val & 0040000)==0040000){ return "D";}
	if(($val & 0020000)==0020000){ return "C";}
	if(($val & 0010000)==0010000){ return "f";}
	return " ";
}

sub do_ls{
	my($path)=@_;
	
	opendir(DIR,$path) or print "\0\0\0" and die "Couldnt open dir [$path]: $!";
	my $dir;
	if(-w $path){
		print "P\t1\t0\t0\n";
	}else{
		print "P\t0\t0\t0\n";
	}	
	while($dir=readdir(DIR)){
		next if substr($dir,0,1) eq '.' or $dir eq 'lost+found';
		my($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
       $atime,$mtime,$ctime,$blksize,$blocks)=lstat($path."/".$dir);
		my @vdate=localtime($mtime);
		my $date=sprintf("%d-%02d-%02d %02d:%02d:%02d",$vdate[5]+1900,$vdate[4]+1,$vdate[3],$vdate[2],$vdate[1],$vdate[0]);
		print parsefilemode($mode)."\t".sizetohuman($size)."\t$date\t$dir\n";
	}
	closedir(DIR);
}


# List file in specified dir
# used by filemgr.php
sub ls {
   my ($user, $path)=@_;

   su($user,"users");
   do_ls($path);
   unsu();
   return $?;

}

#cat file for use with filemgr
sub cat_file {
   my ($file,$user)=@_;
   su($user,"users");
   system("/bin/cat", $file);
   unsu();
}

# Zip files
#
# Args    : prefix - path to remove from archive 
#           name - user that does operation
#
# Input   : Files to zip, one file per line.
#
# Outputs : zipped contents
#
# Returns : Status of operation
sub zip_files{
use IPC::Open3;
   my ($prefix,$user)=@_;

   su($user,"users");

   my $pref2= $prefix;
   $pref2=~s/'/'\\''/g;

   if(substr($prefix,-1,1) ne "/"){
      $prefix.="/";
   }
   my($in, $out, $err);
   my $cmd="cd '$pref2';zip -q -r -0 - -@";
   my $pid=open3($in, $out, $err,$cmd);

   while(<STDIN>){
      $_=~s/^(\Q$prefix\E)//;
	   print $in "$_\n";
   }

   close($in);

   if($err){
	   print "Error: <$err>";
   }

   while(<$out>){
	   print $_;
   }

   waitpid($pid,0);
   unsu();   
   
}

# Set a users unix password
#
# Args   :  name - username
#           pwd -  password to set
#
# Outputs: nothing
#
# Returns: status of operation
#
sub set_unix_password {
   my ($name,$pwd)=@_;

   my $ret;

use IPC::Open3;
   use Crypt::PasswdMD5;
   $pwd=quotemeta unix_md5_crypt($pwd);

   my($wtr, $rdr, $err);
   my $pid = open3($wtr, $rdr, $err,"usermod -p $pwd $name");
   my @rt=<$rdr>;
   my @err=<$err>;
   waitpid($pid,0);

   return $?;

}

# Set samba workgroup
#
# Args   :   group - workgroup to use
#
# Outputs nothing
#
# Returns: status of operation
#
sub set_workgroup {
   my ($workgroup) = @_;
   open(FILE, "/etc/samba/smb.conf") or die "Failed to open file";
   my @data=<FILE>;
   close(FILE);
   chomp(@data);
   my $file=join("\n",@data);
   
   $file =~ s/[^#].*workgroup\s*=.*/\nworkgroup = $workgroup/g;
   
   open(FILE, ">/etc/samba/smb.conf") or die "Failed to open file for writing";
   print FILE $file;
   close(FILE);
}

# Alter users samba password
#
# Args   :  name - user name 
#           old_pwd - users old password
#           new_pwd - users new password
#
# Outputs: nothing
#
# Returns: Status of operation
#
sub set_samba_password {
   my ($name, $old_pwd, $new_pwd)=@_;

   system("echo -e \"$old_pwd\n$new_pwd\" | smbpasswd  $name");

   return $?;

}

# Delete user from system, both samba and unix
#
# Args   : name - user to delete
#
# Outputs: nothing
#
# Return : Status of operation.
sub del_user {
   my ($name)=@_;
   my $ret=0;

   system("userdel $name");
   $ret=$?;
   
   if ($ret==0) {
      system("smbpasswd -x $name");
   }

   return $ret;
}

# Update user information
#
# Args   :  rname - realname for GECOS
#           shell - users shell
#           uname - user to modify
#
# Outputs: nothing
#
# Return : Status of operation.
sub update_user {
   my ($rname, $shell, $uname)=@_;

   if($shell eq ""){
      system("usermod -c \"$rname\" $uname");
   }else{
      system("usermod -c \"$rname\" -s $shell $uname");
   }
   return $?;
}

# Add new user
#
# Args   :  rname - realname for GECOS
#           group - group user should belong to
#           shell - shell for user
#           pwd   - password for user
#           uname - username
#
# Outputs: nothing
#
# Return :  status of operations
#
sub add_user {
   my ($rname, $group, $shell, $pwd, $uname)=@_;
   my $ret;

   use Crypt::PasswdMD5;
   my $c_pwd=quotemeta unix_md5_crypt($pwd);

   $ret=system("useradd -m -c \"$rname\" -g \"$group\" -s $shell -p $c_pwd $uname");
   if ($ret==0) {
      $ret=system("echo -e \"$pwd\n$pwd\" | smbpasswd -s -a $uname");
   }

   # if user existed before, make sure his directory is left accessible to new user
   # This is however a security risk. But we trust the admin to do the right thing.   
   if($ret==0){
	  $ret=system("chown -R $uname:$group /home/$uname");
   }

   return $ret;
}

# Restart samba
#
# Args   : None  
#
# Outputs: nothing
#
# Return : Status of operation.

sub restart_samba {
   system("/etc/init.d/samba restart");

   return $?;
}

# Reload samba
#
# Args   : None  
#
# Outputs: nothing
#
# Return : Status of operation.

sub reload_samba {
   system("/etc/init.d/samba reload");

   return $?;
}

sub write_hostsfile {

my ($lanip,$name) = @_;	
my $cmd = <<END;
127.0.0.1	$name.localdomain $name
127.0.0.1	localhost.localdomain localhost

$lanip	$name.localdomain $name

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
END
      $ret=system("echo -ne \"$cmd\">/etc/hosts");

	
}

# Change hostname
#
# Args   : name - New hostname  
#
# Outputs: nothing
#
# Return : Status of operation.

sub change_hostname {
	my ($name)=@_;
	my $ret;

	$ret=system("echo $name > /proc/sys/kernel/hostname");
	if ($ret==0) {
		$ret=system("echo $name > /etc/hostname");
	}

	if ($ret==0) {
		%ifs = read_interfaces();
		$lan = _get_lanif;
		$lanip = $ifs{$lan}{"options"}{"address"};
		write_hostsfile($lanip,$name);
	}

	if(!query_service("dnsmasq")){
		#restart dnsmasq
		stop_service("dnsmasq");
		start_service("dnsmasq");
	}
   
	if ($ret==0) {

		$ret=system("grep -v \"send host-name\" /etc/dhcp3/dhclient.conf > /etc/dhcp3/dhclient.conf.new");
		if ($ret==0){
			$ret=system("echo send host-name \\\"$name\\\"\\\; >> /etc/dhcp3/dhclient.conf.new");
		}
		if ($ret==0){
			$ret=system("mv /etc/dhcp3/dhclient.conf.new /etc/dhcp3/dhclient.conf");
		}
		if ($ret==0){
			$lan = _get_lanif;
			$ret=system("/sbin/ifup --force eth0 $lan");
		}
	}

	if ($ret==0) {
		if(change_ftp_servername($name)){
			$ret=system("/etc/init.d/proftpd restart");
		}else{
			$ret=1;
		}
	}

	if ($ret==0){
		if(!query_service("avahi-daemon")){
			stop_service("avahi-daemon");
			start_service("avahi-daemon");
		}
	}

	if ($ret==0){
		if(!query_service("mt-daapd")){
			stop_service("mt-daapd");
			sleep(1);
			start_service("mt-daapd");
		}
	}  
	if ($ret==0){
		if(change_upnp_servername($name)){
			if(!query_service("mediatomb")){
				stop_service("mediatomb");
				start_service("mediatomb");
			}
		}
	} 
	return $ret;
}
# Power off
#
# Args   : none  
#
# Outputs: nothing
#
# Return : Status of operation.
sub power_off{
   if( -e "/sys/devices/platform/bubbatwo/magic" ){
   
      open(MAGIC, ">/sys/devices/platform/bubbatwo/magic") or die "Failed to open magic";
      print MAGIC "3735928559\n";
      close(MAGIC);
      return system("/sbin/reboot");
         
   }else{
      return system("/sbin/poweroff");
   }
}

# Dump any file on stdout
#
# Args	: file - filename to dump
#
# Outputs: file contents
#
# Return : Status of operation
sub dump_file {
	my ($file)=@_;
	return system("cat $file");
}

# Restart network
#
# Args   : interface - interface to restart
#
# Outputs: Nothing
#
# Return : Status of operation
sub restart_network{
   my ($if)=@_;
   my $ret;

   $ret=system("/sbin/ifdown $if");
   if ($ret==0) {
      $ret=system("/sbin/ifup $if");
   }
   return $ret;
}


# Local method. 
# Reads /etc/network/interfaces and returns hash with
# adressing="static","dhcp","loopback"
# auto=1 if this interface should be up on boot
# options=key,value of all options to interface, such as address,gw etc
sub read_interfaces{
	open(IFS,"/etc/network/interfaces") or die "Could not open file";
	my @data=<IFS>;
	close(IFS);
	my %ifs;

	my $iface;
	foreach (@data){
		if( /^\s*#/ ){
			next;
		}
		if( /^auto (.+)$/ ){
			$ifs{$1}{"auto"}=1;
			$iface=$1;
		}
		if( /^iface (.+) inet (.+)$/ ){
			$ifs{$1}{"adressing"}=$2;
			$iface=$1;
		}
		if( /^\s+(.+)\s+(.+)$/ ){
			$ifs{$iface}{"options"}{$1}=$2;
		}
	}
	return %ifs;
}

# Wrapper for read_interfaces in order to let frontend read interfaces
sub do_get_interfaces {

	my %ifs = read_interfaces();
	foreach my $iface (keys %ifs){
			print "IF=$iface";
			print " mode=" . $ifs{$iface}{"adressing"};
			if ($ifs{$iface}{"options"}) {
				print " addr=" . $ifs{$iface}{"options"}{"address"};
				print " mask=" . $ifs{$iface}{"options"}{"netmask"};
			}
	print "\n";
	}
}



# Local function
# Writes /etc/network/interfaces back from a hash constructed as
# done by read_interfaces function
sub write_interfaces{
	my %cfg=@_;

	open(FIL,">/etc/network/interfaces") or die "Could not open file for writing"; 
	
	foreach my $iface (reverse sort keys %cfg){
		if($cfg{$iface}{"auto"}){
			print FIL "auto $iface\n";
		}
		print FIL "iface $iface inet ".$cfg{$iface}{"adressing"}."\n";
		if($cfg{$iface}{"options"}){
			while( my($key, $value) = each(%{$cfg{$iface}{"options"}})){
				print FIL "\t$key $value\n";
			}
		}
		print FIL "\n";
	}
	close(FIL);
}

# Set static network config for interface
#
# Args		:	iface 	- Interface to change
#				ip 		- Static ip number
#				nm		- Netmask
#				gw		- Gateway
#
sub set_static_netcfg{
	my ($iface,$ip,$nm,$gw)=@_;
	
	my %ifs=read_interfaces();
	delete $ifs{$iface};
	$ifs{$iface}{"adressing"}="static";
	$ifs{$iface}{"options"}{"address"}=$ip;
	$ifs{$iface}{"options"}{"netmask"}=$nm;
	if($gw ne "0.0.0.0"){
		$ifs{$iface}{"options"}{"gateway"}=$gw;
	}
	write_interfaces(%ifs);
	
	#if(-e "/var/run/dhclient.$iface.pid"){
	if(service_running(dhclient.$iface)) {
		print "KILL service";
		system("kill -INT `cat /var/run/dhclient.$iface.pid`");
	}
	$lan = _get_lanif;
	if($iface eq $lan) { # rewrite host file for local network
		$name = `/bin/cat /etc/hostname`;
		chomp($name);
		write_hostsfile($ip,$name);
	}
}

# Set dynamic networking for interface
#
# Args		:	iface	- Interface to change
sub set_dynamic_netcfg{
	my ($iface)=@_;

	my %ifs=read_interfaces();
	delete $ifs{$iface};
	$ifs{$iface}{"adressing"}="dhcp";
	write_interfaces(%ifs);
}

# Set nameserver
#
# Args		:	ns	- Nameserver to use
sub set_nameserver{
	my ($ns)=@_;
	
	return system("echo -ne 'search\nnameserver $ns\n'>/etc/resolv.conf");
}

# Is service running?
#
# Args   : Service to investigate
#
# Outputs:   0 - service not running
#            1 - service is running
# Return :
sub service_running{
	my ($service)=@_;
	my $pid;
	my $pidfile;
	
	if ($service eq "fetchmail"){
	   $service="fetchmail/.fetchmail";
  }
   
	if ($service eq "avahi-daemon"){
	  $pidfile="/var/run/avahi-daemon/pid";
  } else {
		$pidfile = "/var/run/$service.pid";
	}
	
	if(-e $pidfile){
	   
	   $pid=`cat /var/run/$service.pid`;
	   my @ln=split(/ /,$pid);
	   chomp(@ln);
      $pid=@ln[0];
		if(-e "/proc/$pid"){
			return 1;
		}else{
			return 0;
		}
	}else{
		return 0;
	}
}

# Start service
#
# Args   : Name of service
#
# Return : Status of operation
sub start_service{
   my ($service)=@_;
   
   return system("/etc/init.d/$service start");  
}

sub package_is_installed{
	my($package)=@_;
	return system("dpkg-query -W -f='\${Status}\n' $package 2>&- | grep 'install ok installed'")>>8;
}


# Stop service
#
# Args   : Name of service
#
# Return : Status of operation
sub stop_service{
   my ($service)=@_;
   
   return system("/etc/init.d/$service stop");  
}

# Restart service
#
# Args   : Name of service
#
# Return : Status of operation
sub restart_service{
   my ($service)=@_;
   
   return system("/etc/init.d/$service restart");  
}

# Reload service
#
# Args   : Name of service
#
# Return : Status of operation
sub reload_service{
   my ($service)=@_;
   
   return system("/etc/init.d/$service reload");  
}

# Add service
#
# Args   : Name of service
#
# Return : Status of operation
sub add_service{
   my ($service)=@_;
   
   return system("/usr/sbin/update-rc.d $service defaults");  
}

# Add service att specific init "level"
#
# Args   : service, name of service
#          level , sequence level to start at
#
# Return : Status of operation
sub add_service_at_level{
   my ($service, $level)=@_;

   return system("/usr/sbin/update-rc.d $service defaults $level");
}

# Remove service
#
# Args   : Name of service
#
# Return : Status of operation
sub remove_service{
   my ($service)=@_;
   
   return system("/usr/sbin/update-rc.d -f $service remove");  
}

# Query service
#
# Args   : Name of service
#
# Return : Status of operation
sub query_service{
   my ($service)=@_;

   return system("ls /etc/rc2.d/S??$service &>/dev/null");

}

# Query mail configuration
#
# Args   : None
#
# Outputs: 1 line domains to receive mail for or empty line
#          2 line relayhost or empty line
#          3 hostname 
#          4 smtp auth yes or no
#          5 smtp user or empty line
#
# Return : Status of operation
sub get_mailcfg{

	if ( -e "/etc/postfix/bubbadomains" ){
		open DOMS, "</etc/postfix/bubbadomains" or die "Could not open domain file";
		my @lines=<DOMS>;
		close DOMS;
		chomp @lines;
		print join " ",@lines;
		print "\n";
	}else{
		print "\n";
	}

   	print `/usr/sbin/postconf -h relayhost myhostname smtp_sasl_auth_enable smtp_sasl_security_options`;

	if (-e "/etc/postfix/sasl_passwd"){
		open FILE, "</etc/postfix/sasl_passwd" or die "Could not open sasldb";
		my $line=<FILE>;
		close FILE;
		if($line=~/^.+\s+(.*?):.+$/){
			print "$1\n";
		}else{
			print "No match\n";
		}
	}else{
		print "\n";
	}
}

# Write send mail cfg
#
# Args    : mailhost
#         : smtp auth - yes or no
#         : smtp user
#         : smtp passwd
sub write_send_mailcfg{
	my ($mailhost,$auth,$user,$passwd,$plain_auth)=@_;
	$user =~ s/://g; # remove ':' as sasl_password have no mechanics to allow such chars
	my $security_options = "smtp_sasl_security_options=\"noplaintext, noanonymous\"";
	
	if($auth eq "yes"){
		open(FILE,">/etc/postfix/sasl_passwd") or die "Could not open file";
		print FILE "$mailhost\t$user:$passwd\n";
		close FILE;
		my $gid=getgrnam("postfix") or die "Could not get gid of group [postfix]";
		chown(-1,$gid,"/etc/postfix/sasl_passwd");
		chmod(0640,"/etc/postfix/sasl_passwd");
		system("/usr/sbin/postmap /etc/postfix/sasl_passwd");
		if( $plain_auth eq "yes" ) {
			$security_options = "smtp_sasl_security_options=noanonymous";
		}
	}
	
	return system("/usr/sbin/postconf -e relayhost=\"$mailhost\" smtp_sasl_auth_enable=$auth smtp_sasl_password_maps=hash:/etc/postfix/sasl_passwd $security_options");
}

# Write receive mail cfg
#
# Args    : domain - domain to retreive mail for
#
sub write_receive_mailcfg{
	my ($domain)=@_;

	open FIL, ">/etc/postfix/bubbadomains" or die "Could not open domains file for write";
	my @dom=split /\s+/, $domain;
	foreach (@dom){
		print FIL "$_\n";
	}
	close FIL;
}

# Read fetchmail accounts
# 
# Helper function reads out all fetchmail accounts into an
# array of arrays.
#
sub read_fetchmailaccounts{
   open(FILE, "/etc/fetchmailrc") or return;
   my @data=<FILE>;
   close(FILE);

   my @ret;   
   my $host;
   my $proto;
   my $uidl;      
   my $keep;      
   my $ssl;      
   my $password;      
   foreach (@data){
   		$ssl = "";
   		$keep = "";
   		
      if( /^poll ([^\s]*)\s*(uidl)*\s*with proto (.*)/ ){
      	$host = $1;
				$proto=$3;
      }
			if ( /ssl/ ) {
				$ssl = "ssl";
			}
			if ( /keep/ ) {
				$keep = "keep";
			}

      if (/^\tuser '(.*)' there with password '(.*)' is '(.*)' here/){
         push @ret, [$host, $proto, $1, $2, $3, $ssl,$keep];
      }
   }
   return @ret;

}

sub write_fetchmailaccounts{

   my @data=@_;

   open(FILE,">/etc/fetchmailrc") or die "Could not open file";

   print FILE "set postmaster \"postmaster\"\n";
   print FILE "set bouncemail\n";
   print FILE "set no spambounce\n";
   print FILE "set properties \"\"\n";
   print FILE "set daemon 300\n";
   print FILE "set syslog\n";
   
   my $line;
   my ($host,$proto,$keep,$uidl);

   foreach $line (@data){

			my $len = scalar(@{$line});
			if(@{$line}[$len-1] eq "keep") {
				$keep = "keep";
				$uidl = " uidl";
			} else {
				$keep = "";
				$uidl = "";
			}			
			
			if($host ne @{$line}[0] || $proto ne @{$line}[1]){
			   $host=@{$line}[0];
			   $proto=@{$line}[1];
			   print FILE "\npoll $host$uidl with proto $proto\n";
			}
			print FILE "\tuser '".@{$line}[2]."' there with password '".@{$line}[3]."' is '".@{$line}[4]."' here ".@{$line}[5]." $keep\n";
   }
   close FILE;
}


# Get fetchmail acccounts
#
# Args   : None
#
# Outputs: fetchmailacounts one line per account
#          Syntax on line: host protocol username password local_user (optional) ssl 
#
# Return : None   
#
sub get_fetchmailaccounts{

   my @data=read_fetchmailaccounts();
   my $line;
   foreach $line (@data){
      print join " ", @{$line};
      print "\n";
  }
}

# Add fetchmail acccount
#
# Args   : host 
#          protocol
#          remote username
#          password
#          local username
#          ssl "ssl" or "NONE"  
#
# Outputs: Nothing
#
# Return : None   
#
sub add_fetchmailaccount{
	my ($host, $proto, $ruser, $pwd, $luser, $ssl,$keep)=@_;
	
	my @indata=read_fetchmailaccounts();
	my @outdata;
	my $found=0;
	my $line;
	
	if ($keep eq "NONE") {
		$keep = "";
	}
	
	foreach $line (@indata){
		push @outdata, [@{$line}];
		if( !$found && @{$line}[0] eq $host && @{$line}[1] eq $proto){
			$found=1;
			if($ssl ne "NONE"){
				push @outdata, [$host, $proto, $ruser, $pwd, $luser, $ssl, $keep];
			}else{
				push @outdata, [$host, $proto, $ruser, $pwd, $luser, $keep];
			}
		}
	}
	
	if (!$found){
		if($ssl ne "NONE"){
			push @outdata, [$host, $proto, $ruser, $pwd, $luser, $ssl , $keep];
		}else{
			push @outdata, [$host, $proto, $ruser, $pwd, $luser, $keep];
		}
	}
	
	write_fetchmailaccounts(@outdata);

}

# Update fetchmail acccount
#
# Args   : old host
#          old protocol
#          old remote user 
#          new host 
#          new protocol
#          new remote username
#          new password
#          new local username
#          new ssl "ssl" or "NONE"  
#
# Outputs: Nothing
#
# Return : None   
#
sub update_fetchmailaccount{
	
   my ($o_host, $o_proto, $o_ruser, $host, $proto, $ruser, $pwd, $luser, $ssl, $keep)=@_;
   my @indata=read_fetchmailaccounts();
   my @outdata;
   my $found=0;
   my $line;
	 
	foreach $line (@indata){
		if( @{$line}[0] eq $o_host && @{$line}[1] eq $o_proto && @{$line}[2] eq $o_ruser){
		  $found=1;
		  if($ssl eq "NONE") {
		   	$ssl = "";
		  }
		  if($keep eq "NONE") {
		   	$keep = "";
		  }
		  unless($pwd =~ m/[^\*]/) {
				$pwd = @{$line}[3];
			}
		  push @outdata, [$host, $proto, $ruser, $pwd, $luser, $ssl, $keep];
		
		}else{
		   push @outdata, [@{$line}];
		}  
	}

	write_fetchmailaccounts(@outdata);

}


# Delete fetchmail acccount
#
# Args   : host 
#          protocol
#          remote username
#
# Outputs: Nothing
#
# Return : None   
#
sub delete_fetchmailaccount{
   my ($host, $proto, $ruser)=@_;

   my @indata=read_fetchmailaccounts();

   my @outdata;
   my $line;
   foreach $line (@indata){
      if( (@{$line}[0] eq $host) && (@{$line}[1] eq $proto) && (@{$line}[2] eq $ruser)){
         # Dont add this one to outarray it should be deleted.
      }else{
         push @outdata, [@{$line}];
      }  
  }

   write_fetchmailaccounts(@outdata);

}

# Helper function change proftp servername
#
# Args   : New servername
#
# Outputs: Nothing
#
# Return: 0 - Operation failed
#         1 - Operation ok
sub change_ftp_servername{
	my $name=shift;

	if(not $name=~ /^[\w-]*$/){
		return 0;
	}
 
	open( CONF,"/etc/proftpd/proftpd.conf") or die "Could not open config file";
	my @data=<CONF>;
	close(CONF);

	chomp(@data);
	my $file=join("\n",@data)."\n";
	
	if(  $file =~ s/ServerName\s*"([\w-]*)"/ServerName\t\t\t"$name"/g){
		open( CONF,">/etc/proftpd/proftpd.conf") or die "Could not open config file";
		print CONF $file;
		close CONF;
		return 1;
	}
	
	return 0;

}

# Check status of anonymous ftp access
#
# Args   : None
#
# Outputs: Nothing
#
# Return: 0 - No anonymous access allowed
#         1 - Anonymous access allowed
#        -1 - Unable to parse configuration
sub ftp_check_anonymous{ 
	open( CONF,"/etc/proftpd/proftpd.conf") or die "Could not open config file";
	my @data=<CONF>;
	close(CONF);

	chomp(@data);
	my $file=join("\n",@data)."\n";

	if(  $file =~ /\<Anonymous.*\n.*\<Limit LOGIN\>\n\s*(\w*)\n/g){
		if($1 eq "DenyAll"){
			return 0;
		}elsif($1 eq "AllowAll"){
			return 1;
		}
	}
	return -1;
}

# Set anonymous ftp access
#
# Args   : 1 - Enable anonymous access
#          0 - Disable anonymous access
# 
# Outputs:   Nothing
#
# Return:  1 - Operation successful
#          0 - Operation failed   
sub ftp_set_anonymous{
   my $val=shift;
 
	open( CONF,"/etc/proftpd/proftpd.conf") or die "Could not open config file";
   my @data=<CONF>;
   close(CONF);

   chomp(@data);
   my $file=join("\n",@data)."\n";
	
	my $rep;
	if($val){
        	$rep="AllowAll";
	}else{
	 	$rep="DenyAll";
	} 

   if(  $file =~ s/(\<Anonymous.*\n.*\<Limit LOGIN\>\n\s*)(\w*)\n/$1$rep\n/g){
      open( CONF,">/etc/proftpd/proftpd.conf") or die "Could not open config file";
      print CONF $file;
   	close CONF;
      return 1;
   }
   return 0;

}
# Helper function change mediatomb servername
#
# Args   : New servername
#
# Outputs: Nothing
#
# Return: 0 - Operation failed
#         1 - Operation ok

sub change_upnp_servername{
   my $name=shift;

   if(not $name=~ /^[\w-]*$/){
      return 0;
   }
 
   open( CONF,"/etc/mediatomb/config.xml") or die "Could not open config file";
   my @data=<CONF>;
   close(CONF);

   chomp(@data);
   my $file=join("\n",@data)."\n";
        
   if(  $file =~ s/^(\s*)<name>\s*(.*)<\/name>/$1<name>$name<\/name>/mg){
      open( CONF,">/etc/mediatomb/config.xml") or die "Could not open config file";
      print CONF $file;
      close CONF;
      return 1;
   }
        
   return 0;

}


# Helper function change mt-daapd servername
#
# Args   : New servername
#
# Outputs: Nothing
#
# Return: 0 - Operation failed
#         1 - Operation ok
sub change_daap_servername{
	my $name=shift;

	if(not $name=~ /^[\w-]*$/){
		return 0;
	}
 
	open( CONF,"/etc/mt-daapd.conf") or die "Could not open config file";
	my @data=<CONF>;
	close(CONF);

	chomp(@data);
	my $file=join("\n",@data)."\n";
	
	if(  $file =~ s/^\s*servername\s*([\w-]*)/servername\t$name/mg){
		open( CONF,">/etc/mt-daapd.conf") or die "Could not open config file";
		print CONF $file;
		close CONF;
		return 1;
	}
	
	return 0;

}


# Mount partition
#
# Args   : device     - block device to mount
#	   mountpoint - path on where to mount device
#          fstype     - optional filesystemtype left out or empty triggers probe
#
# Outputs: nothing
#
# Return:  Status of operation
sub mount{
  my ($device,$mountpoint,$fstype)=@_;

  $device or return -1;
  $mountpoint or return -1;
  if($fstype && ($fstype!="")){
	$fstype="-t $fstype";
  }else{
  	$fstype or $fstype="";
  }

  return system("/bin/mount $fstype $device $mountpoint");
}

# Umount partition
#
# Args   : device     - block device to umount
#
# Outputs: nothing
#
# Return:  Status of operation
sub umount{
  my $mountpoint=shift;

  return system("/bin/umount $mountpoint");
}


# Create backup of system settings
#
# Args   : Absolute path to where backup should be stored
#
# Outputs: gzipped tar archive of system setting files
#
# Return:  Status of operation
sub backup_config{
	my $path=shift;

	use open ':utf8';
	use POSIX qw(strftime);
	use File::Slurp;
	use File::Temp qw(tempdir);
	use Storable qw(nstore);
	use File::Glob ':glob';
	use File::Basename;
	use JSON;

	my $tempdir = tempdir( CLEANUP => 1 );

	my $psettings = "/usr/share/bubba-configs/personal-setting-files.txt";
	chomp(my @psettings_data = read_file( $psettings ));
	my $timestring = strftime "%Y-%m-%dT%H%M%S", gmtime;
	my $filename = "$path/bubbatwo-$timestring.backup";
	my $ret = 0;

	# current format revision
	my $revision = 1;

	# We gather user data from /etc/shadow and /etc/passwd, we'll only remember groups which 
	# specific users belong to.
	my @bubba_users = map { 
		my(undef,undef,$uid,$gid,$comment,$homedir,$shell) = split ':', `getent passwd $_->{username}`; 
		$_->{uid} = $uid; 
		$_->{gid} = $gid; 
		$_->{comment} = $comment; 
		$_->{homedir} = $homedir; 
		chomp( $_->{shell} = $shell); 
		chomp (my $groups = `id -Gn $_->{username}`);
		@{$_->{groups}} = split ' ', $groups;
		chomp( $_->{main_group} = `id -gn $_->{username}` );
		$_->{has_bubbacfg} =  -f "/home/$_->{username}/.bubbacfg" ? 1 : 0;
		$_->{has_backup} =  -d "/home/$_->{username}/.backup" ? 1 : 0;
		\%$_;
	} map {
		pop@$_;
		{username => $_->[0], password => $_->[1]}
	} grep {
		length $_->[1] > 2
	} map {
		[split ':', $_, 3]
	} read_file( '/etc/shadow' );

	# services, boolean such if service enabled or not
	my %services = map {
		$_ => (defined bsd_glob "/etc/rc2.d/S??$_");
	} qw(proftpd mt-daapd ntp filetransferdaemon cups postfix dovecot fetchmail mediatomb dnsmasq squeezecenter hostapd netatalk ifup-br0);

	my $meta = {
		version => $revision,
		services => \%services,
		users => \@bubba_users,
		date => scalar gmtime
	};

	# We save this as JSON to use as metadata
	write_file( "$tempdir/meta.json", to_json( $meta, {utf8 => 1, pretty => 1}));

	my $ret = system(
		"tar", 
		'--directory', '/',
		"--create", 
		"--file", "$tempdir/system.tar.gz", 
		"--gzip",
		"--force-local", 
		"--ignore-failed-read",
		"--preserve",
		"--same-owner",
		"--absolute-names",
		"--atime-preserve",
		grep { -f $_ || -l $_ } map { bsd_glob $_ } grep { !/^(#|\s*$)/ } @psettings_data,
	) >> 8;

	$ret |= system(
		"tar", 
		'--directory', '/',
		"--create", 
		"--file", "$tempdir/user.tar.gz",
		"--gzip",
		"--force-local", 
		"--ignore-failed-read",
		"--preserve",
		"--same-owner",
		"--absolute-names",
		"--atime-preserve",
		glob ("/home/*/.bubbacfg"),
		glob ("/home/*/.backup"),
	) >> 8;

	# We combine the above files into an tar file
	$ret |= system(	
		"tar", 
		"--create",
		'--directory', $tempdir,
		"--file", "$filename",
		map{ basename( $_ ) } glob( "$tempdir/*" )
	) >> 8;

	return $ret;
}

# Restore backup of system settings
#
# Args   : Absolute path to use for restore
#          A savefile matching the bubbabackup-*.img is supposed to be found there.
#
# Outputs: Nothing
#
# Return:  Status of operation
sub restore_config{
	use IPC::Open3;
	use File::Slurp;
	use File::Temp qw(tempdir :POSIX);
	use JSON;

	my $pathname=shift;

	my @files=<$pathname/bubbatwo-*.backup>;
	if( scalar @files > 0 ) {
		my $latest_archive = $files[-1];
		my $tempdir = tempdir( CLEANUP => 1 );

		system(
			'tar', 
			'--extract',
			'--directory', $tempdir,
			'--file', $latest_archive
		);
		my $meta = from_json( read_file "$tempdir/meta.json" );
		my $recorded_version = defined $meta->{version} ? $meta->{version} : 0;
		my %recorded_users =map { $_->{username} => $_ } defined $meta->{users} ? @{$meta->{users}} : [];

		my %current_users = map {
			$_->[0] => 1
		} grep {
			length $_->[1] > 2
		} map {
			[split ':', $_, 3]
		} read_file( '/etc/shadow' );

		my (%existing_users, %removed_users);

		foreach my $user( keys %recorded_users ) {
			unless( defined $current_users{$user} ) {
				$existing_users{$user} = 0;
			} else {
				$existing_users{$user} = 1;
			}
		}

		foreach my $user( keys %current_users ) {
			$removed_users{$user} = 1 unless defined $recorded_users{$user};
		}
		if( scalar keys %removed_users > 0 ) {
			# Stop ftd so any delete of users doesn't fnuck stuff upp
			system(
				'/etc/init.d/filetransferdaemon',
				'stop'
			);
		}

		foreach my $euser( keys %existing_users ) {
			my $user = $recorded_users{$euser};
			my $action = $existing_users{$euser} ? 'usermod' : 'useradd';
			foreach my $group( @{$user->{groups}} ) {
				unless( system("/usr/bin/getent group $group &>/dev/null") >> 8 == 0 ) {
					system(
						'groupadd',
						'--force',
						$group
					);
				}
			}
			system(
				"/usr/sbin/$action",
				'--groups', join( ',', @{$user->{groups}}),
				'--gid', $user->{main_group},
				'--home', $user->{homedir},
				'--comment', $user->{comment},
				'--password', $user->{password},
				'--shell', $user->{shell},
				'--create-home',
				$user->{username}
			);
		}

		foreach my $user( keys %removed_users ) {
			system(
				'/usr/sbin/deluser',
				'--quiet',
				$user
			);
		}

		# We can extract system right away
		system(
			'/bin/tar',
			'--extract',
			'--gzip',
			'--directory', '/',
			'--file', "$tempdir/system.tar.gz",
			'--atime-preserve',
			'--preserve',
			'--same-owner',
			'--absolute-name'
		);

		# we remove _all_ .bubbacfg and .backup files/dirs
		system(
			'/bin/rm',
			'--recursive',
			'--force',
			glob ("/home/*/.bubbacfg"),
			glob ("/home/*/.backup")
		);

		# unpack all user data
		system(
			'/bin/tar',
			'--extract',
			'--gzip',
			'--directory', '/',
			'--file', "$tempdir/user.tar.gz",
			'--atime-preserve',
			'--preserve',
			'--same-owner',
			'--absolute-name'
		);

		system("/sbin/iptables-restore","/etc/network/firewall.conf");
		system("/bin/cp","/etc/hostname","/proc/sys/kernel/hostname");

		restart_network("eth0");
		$lan = _get_lanif;
		restart_network($lan);
		reload_service("samba");
		reload_service("apache2");

		# start or stop services
		while( my( $service, $status ) = each( %{$meta->{services}} ) ) {
			if( $status ) {
				unless( query_service( $service ) == 0 ) {
					add_service( $service );
				}
				if( service_running( $service ) ) {
					restart_service( $service );
				} else {
					start_service( $service );
				}
			} else {
				if( service_running( $service ) ) {
					stop_service( $service );
				}
				if( query_service( $service ) == 0 ) {
					remove_service( $service );
				}
			}
		}
		return 0;
	} else {
		# old type of system backup
		my @old_files=<$pathname/bubbatwo-backup-*.tar.gz>;

		if(@old_files){

			# some sort of username handling for old backups
			my $tempfile = tmpnam();
			my $tempdir = tempdir( CLEANUP => 1 );
			write_file( $tempfile, [ '/etc/passwd', '/etc/shadow', '/etc/group' ] );

			system(
				'tar',
				'--extract',
				'--gzip',
				'--files-from', $tempfile,
				'--file', $old_files[-1],
				'--directory', $tempdir
			);
			my @bubba_users = map { 
				my $__=$_;
				my @passwd = grep {$_->[0] eq $__->{username}} map { chomp; $_ } map {[split ':'] } read_file( "$tempdir/etc/passwd" );
				print Dumper @passwd;
				my(undef,undef,undef,undef,$comment,$homedir,$shell) = @{$passwd[0]};
				$_->{comment} = $comment; 
				$_->{homedir} = $homedir; 
				chomp( $_->{shell} = $shell); 
				\%$_;
			} map {
				pop@$_;
				{username => $_->[0], password => $_->[1]}
			} grep {
				length $_->[1] > 2
			} map {
				[split ':', $_, 3]
			} read_file( "$tempdir/etc/shadow" );

			foreach my $user ( @bubba_users ) {
				my $action = 'usermod';
				unless( system("/usr/bin/getent passwd $user &>/dev/null") >> 8 == 0 ) {
					$action = 'useradd';
				}
				system(
					"/usr/sbin/$action",
					'--gid', 'users',
					'--home', $user->{homedir},
					'--comment', $user->{comment},
					'--password', $user->{password},
					'--shell', $user->{shell},
					$user->{username}
				);
			}

			my($in, $out, $err);
			my $pid = open3($in, $out, $err,"cd /;tar --extract --gzip --verbose --file ".quotemeta($old_files[-1])." --atime-preserve --preserve --same-owner --absolute-names --exclude-from $tempfile");

			unlink $tempfile;
			my $lines=join("",<$out>);
			waitpid($pid,0);

			restart_network("eth0");
			$lan = _get_lanif;
			restart_network($lan);

			system("/sbin/iptables-restore < /etc/network/firewall.conf");

			system("echo `cat /etc/hostname` > /proc/sys/kernel/hostname");

			if($lines=~/proftpd/){
				start_service("proftpd");
			}else{
				stop_service("proftpd");
				remove_service("proftpd");
			}

			if($lines=~/mt-daapd/){
				start_service("mt-daapd");
			}else{
				stop_service("mt-daapd");
				remove_service("mt-daapd");
			}

			if($lines=~/mediatomb/){
				start_service("mediatomb");
			}else{
				stop_service("mediatomb");
				remove_service("mediatomb");
			}

			if($lines=~/filetransferdaemon/){
				start_service("filetransferdaemon");
			}else{
				stop_service("filetransferdaemon");
				remove_service("filetransferdaemon");
			}

			if($lines=~/postfix/){
				start_service("postfix");
				reload_service("postfix");
			}else{
				stop_service("postfix");
				remove_service("postfix");
			}

			if($lines=~/dovecot/){
				start_service("dovecot");
			}else{
				stop_service("dovecot");
				remove_service("dovecot");
			}

			if($lines=~/fetchmail/){
				start_service("fetchmail");
			}else{
				stop_service("fetchmail");
				remove_service("fetchmail");
			}

			if($lines=~/cups/){
				start_service("cups");
				reload_service("cups");
			}else{
				stop_service("cups");
				remove_service("cups");
			}

			if($lines=~/dnsmasq/){
				stop_service("dnsmasq");
				start_service("dnsmasq");
			}else{
				stop_service("dnsmasq");
				remove_service("dnsmasq");
			}

			if($lines=~/squeezecenter/){
				stop_service("squeezecenter");
				start_service("squeezecenter");
			}else{
				stop_service("squeezecenter");
				remove_service("squeezecenter");
			}

			reload_service("samba");

			reload_service("apache2");

		}else{
			return -1;
		}
		return 0;
	}
}


sub do_echo{
	my ($arg)=@_;
	print "Echo: $arg\n";
}


sub dnsmasq_config {
	my ($dhcpd,$range_start,$range_end,$ifs) = @_;
	open(FILE, "/etc/dnsmasq.conf") or die "Failed to open file";
	my @data=<FILE>;
	chomp(@data);
	close(FILE);
	my $file=join("\n",@data);

	$lan = $ifs;
	if($dhcpd) { # enable dhcpd on LANINTERFACE.
		$file =~ s/no-dhcp-interface=$lan\n*/ /g;
	} else { # disable dhcpd on LANINTERFACE.
		$file .= "\nno-dhcp-interface=$lan\n";
	}
	$file =~ s/(interface\s*=\s*)(\w+)/$1$ifs/g;
	$file =~ s/(dhcp-range\s*=\s*)[\d\.]+,[\d\.]+/$1$range_start,$range_end/g;
	$file =~ s/[\s\n]*$//;
	$file .= "\n";

	open(FILE, ">/etc/dnsmasq.conf") or die "Failed to open file for writing";
	print FILE $file;
	close(FILE);
}

sub easyfind {
	
	my ($cmd,$name) = @_;
	if (!$name) {
		$name = "";
	}
	if (!$cmd) {
		$cmd = "";
	}
	return system("/usr/lib/web-admin/easyfind.pl $cmd $name");
	
}

sub do_get_version {
use IPC::Open3;

	 my $package = shift;
	 if ($package !~ m/[;\n:]/) { # make some sanity check
	   my($wtr, $rdr, $err);
	   my $pid = open3($wtr, $rdr, $err,"/usr/bin/dpkg -l $package");
	   my @rt=<$rdr>;
	   my @err=<$err>;
	   waitpid($pid,0);
	   
	   print @rt;
	} else {
		return 0;
	}
}

sub get_link{
	my $iface=shift;
	my $link=0;
		
	my @lines=`ethtool $iface 2>/dev/null`;
	foreach $line (@lines){
		if( $line =~ /\s*Speed: (\d+)Mb\/s/){
			$link=$1;
		}
	}
	print "$link\n";
	return 0;
}

# TODO logic
# Get MTU of LAN
#
# Outputs: current _wanted_ mtu
#
# Returns: status of operation
sub get_mtu{
	my $ret=1500;
	$lan = _get_lanif;
	if(open(FILE, "/etc/network/mtu-$lan.conf")){
		foreach(<FILE>){
			if ( $_ =~ /\s*MTU\s*=\s*(\d+)/){
				$ret=$1;
			}
		}
		close(FILE);
	}else{
		# No file, try sys
		if(open(FIL, "/sys/class/net/$lan/mtu")){
			$ret=<FIL>;
			chomp($ret);
			close(FIL);
		}
	}
	print "$ret\n";
	return 0;
}

# TODO logic
# Set MTU on LAN
#
# Input:	mtu - wanted mtu
# Outputs:	none
# Returns:	Status of operation
sub set_mtu{
	my $mtu=shift;
	$lan = _get_lanif;
	if(open(FILE, ">/etc/network/mtu-$lan.conf")){
		print FILE "MTU=$mtu\n";
		close(FILE);
		if(open(FIL, ">/sys/class/net/$lan/mtu")){
			print FIL "$mtu\n";
			close(FIL);
		}else{
			return 1;
		}
		return 0;
	}else{
		return 1;
	}
}

sub do_update_bubbacfg {
	use Config::Tiny;
	my ($user,$param,$value) = @_;

	my $config_file = "/home/$user/.bubbacfg";

	my $config = Config::Tiny->read( $config_file ) || Config::Tiny->new();
	$config->{_}->{$param} = $value;
	$config->write( $config_file );
}

sub do_get_timezone {

	my $tz_path;
	$tz_path = `ls -l /etc/localtime`;
	$tz_path =~ m/\/usr\/share\/zoneinfo\/(\w+)\/(\w+)$/;
	if(!($1 && $2)) {
		print "UTC";
	} else {
		print "$1/$2";
	}
}

sub do_set_timezone {
	
	my ($timezone) = @_;
	my $ret;
	my $cmd;
	
	$cmd = "ln -sf '/usr/share/zoneinfo/$timezone' '/etc/localtime'";
	$ret = system($cmd);
	$cmd = "echo '$timezone' > '/etc/timezone'";
	$ret = system($cmd);
	if($ret) {
		print 1;
	} else {
		print 0;			
	}
	return $ret;
}

sub _get_lanif {
	return `/usr/bin/bubba-networkmanager-cli getlanif`;
}

sub _notify_read_config {
	return {} unless -f "/etc/bubba-notify/bubba-notify.conf";
	return do "/etc/bubba-notify/bubba-notify.conf" || {};
}

sub _notify_write_config {
	use Data::Dumper;
	$Data::Dumper::Terse = 1;
	$Data::Dumper::Indent = 1;
	open CONF, '>', "/etc/bubba-notify/bubba-notify.conf";
	print CONF Dumper $_[0];
	close CONF;
}

sub _notify_list {
	# TODO external config?
	return [ 'led', 'ui', 'email' ];
}

sub _notify_enable {
	my( $type ) = @_;

	if( -f "/etc/bubba-notify/enabled/$type" ) {
		unlink "/etc/bubba-notify/enabled/$type";
	}

	system( 'ln', '-s', "/etc/bubba-notify/available/$type" , "/etc/bubba-notify/enabled/$type" );
}

sub _notify_disable {
	my( $type ) = @_;

	unlink "/etc/bubba-notify/enabled/$type";

	# all "plugins" have at least $type in cache, 
	# if they have more they must have the name $type\_blabla
	unlink "/var/cache/bubba-notify/$type";
	unlink glob("/var/cache/bubba-notify/$type\_*");
}

sub _makeControl
{
	my ($dataorarrayref) = @_;
	
	my $str = "";

	foreach my $stanza(@$dataorarrayref)
	{
		foreach my $key(keys %$stanza)
		{
			$stanza->{$key} ||= "";

			my @lines = split("\n", $stanza->{$key});
			if (@lines) {
				$str.="$key\: ".(shift @lines)."\n";
			} else {
				$str.="$key\:\n";
			}

			foreach(@lines)
			{
				if($_ eq "")
				{
					$str.=" .\n";
				}
				else{
					$str.=" $_\n";
				}
			}

		}

		$str ||= "";
		$str.="\n";
	}

	chomp($str);
	return $str;
	
}

sub _notify_write_spool {
	my ( $data ) = @_;
	my $uuid = $data->{UUID};
	open SPOOL, '>>', "/var/spool/bubba-notify/$uuid" or die "Couldn't open spool: $!";
	print SPOOL _makeControl( [$data] )."\n\n";
	close SPOOL;
}

sub notify_start {
	my $conf = &_notify_read_config;

	$conf->{enabled} = 1;
	foreach my $notify ( &_notify_list ) {
		_notify_enable( $notify ) if $conf->{"$motify\_level"} > 0;
	}

	&_notify_write_config( $conf );
}

sub notify_stop {
	my $conf = &_notify_read_config;

	$conf->{enabled} = 0;

	foreach my $notify ( &_notify_list ) {
		_notify_disable( $notify );
	}

	system( 'rm', '-f', glob('/var/spool/bubba-notify/*') );

	&_notify_write_config( $conf );
}

sub notify_enable {
	my( $type, $level ) = @_;
	
	my $conf = &_notify_read_config;
	
	$conf->{"$type\_level"} = $level;
	
	_notify_enable( $type );

	&_notify_write_config( $conf );
}

sub notify_disable {
	my( $type ) = @_;
	
	my $conf = &_notify_read_config;
	
	$conf->{"$type\_level"} = 0;
	
	_notify_disable( $type );

	&_notify_write_config( $conf );
}

sub notify_ack {
	my( $uuid ) = @_;
	_notify_write_spool({UUID => $uuid, Action => 'ACC'});
}

sub notify_flush {
	system('/usr/lib/web-admin/notify-dispatcher.pl');
}

sub set_interface {

    use Config::Tiny;
    use XML::LibXML;
    use File::Slurp;

    my( $interface ) = @_;

    {
        my $config = '/etc/samba/smb.conf';

        my $cfg = Config::Tiny->read( $config );
        $cfg->{global}->{interfaces} = $interface;
        $cfg->write( $config );
    }

    {
        my $config = '/etc/mediatomb/config.xml';

        my $parser = new XML::LibXML();
        my $xpc = new XML::LibXML::XPathContext();

        my $doc = $parser->parse_file( $config );
        $xpc->registerNs('m', "http://mediatomb.cc/config/1");

        my $nodes = $xpc->findnodes("/m:config/m:server/m:interface", $doc);
        
        return 1 if $nodes->size() == 0;

        my $node = $nodes->get_node(1);
        $node->removeChildNodes();
        $node->appendTextNode( $interface );

        $doc->toFile( $config, 1 );
    }

    {
        my $config = '/etc/default/mediatomb';

        my $data = read_file( $config );

        return 1 unless $data =~ s/^\s*INTERFACE\s*=\s*".*?"\s*?$/INTERFACE="$interface"/m;

        write_file( $config, $data );
    }

    {
        my $config = '/etc/cups/cupsd.conf';

        my $data = read_file( $config );

        return 1 unless $data =~ s/\@IF\(.*?\)/\@IF($interface)/g;

        write_file( $config, $data );
    }

    {
        my $config = '/etc/dhcp3/dhclient.conf';

        my $data = read_file( $config );

        return 1 unless $data =~ s/interface ".*?";/interface "$interface";/g;

        write_file( $config, $data );
    }

    return 0;
}
