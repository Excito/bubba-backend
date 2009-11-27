#! /usr/bin/perl

use Bubba;

# This is the administrative backend of bubba.
# All activities that require elevated privilges are collected here
# and this application is then added to the sudoers file.

# TODO
#        - Perhaps verify input data better. Or perhaps leave that to web-admin app
#        - Evaluate if we should use perlcc ie "perlcc -B backend.pl" to produce bytecode
 

#use strict;


# Hash with all commands
# Key 	- name to use when called
# value	- function to be called and number of arguments
my %commands=(
	# User commands
	"set_unix_password" 	=> [\&Bubba::set_unix_password,2],
	"set_workgroup" 		=> [\&Bubba::set_workgroup,1],
	"set_samba_password"	=> [\&Bubba::set_samba_password ,3],
	"del_user"				=> [\&Bubba::del_user ,1],
	"update_user"			=> [\&Bubba::update_user ,3],
	"add_user"				=> [\&Bubba::add_user ,5],
	# Services
	"restart_samba"			=> [\&Bubba::restart_samba ,0],
	"reload_samba"			=> [\&Bubba::reload_samba ,0],
	"change_hostname"		=> [\&Bubba::change_hostname ,1],
	"power_off"				=> [\&Bubba::power_off ,0],
	"dump_file"				=> [\&Bubba::dump_file ,1],
	"restart_network"		=> [\&Bubba::restart_network ,1],
	"set_static_netcfg"		=> [\&Bubba::set_static_netcfg ,4],
	"set_dynamic_netcfg"	=> [\&Bubba::set_dynamic_netcfg ,1],
	"set_nameserver"		=> [\&Bubba::set_nameserver ,1],
	"service_running"		=> [\&Bubba::service_running ,1],
	"start_service"			=> [\&Bubba::start_service ,1],
	"reload_service"		=> [\&Bubba::reload_service ,1],
	"restart_service"		=> [\&Bubba::restart_service ,1],
	"stop_service"			=> [\&Bubba::stop_service ,1],
	"add_service"			=> [\&Bubba::add_service ,1],
	"add_service_at_level"		=> [\&Bubba::add_service_at_level,2],
	"remove_service"		=> [\&Bubba::remove_service ,1],
	"query_service"			=> [\&Bubba::query_service ,1],
	"package_is_installed"	=> [\&Bubba::package_is_installed, 1],
	# System
	"power_off"				=> [\&Bubba::power_off ,0],
	"set_time"				=> [\&Bubba::set_time ,2],
	"backup_config"			=> [\&Bubba::backup_config ,1],
	"restore_config"		=> [\&Bubba::restore_config ,1],
	"mount"					=> [\&Bubba::mount ,3],
	"umount"				=> [\&Bubba::umount ,1],
	"uptime"				=> [\&Bubba::uptime ,0],
	"get_hdtemp"			=> [\&Bubba::get_hdtemp ,1],
	"get_version"			=> [\&Bubba::do_get_version,1],
	# Network
	"change_hostname"		=> [\&Bubba::change_hostname ,1],
	"restart_network"		=> [\&Bubba::restart_network ,1],
	"set_static_netcfg"		=> [\&Bubba::set_static_netcfg ,4],
	"set_dynamic_netcfg"	=> [\&Bubba::set_dynamic_netcfg ,1],
	"set_nameserver"		=> [\&Bubba::set_nameserver ,1],
	"dnsmasq_config"		=> [\&Bubba::dnsmasq_config ,3],
	"easyfind"				=> [\&Bubba::easyfind ,2],
	"get_interfaces"		=> [\&Bubba::do_get_interfaces,0],
	"get_link"				=> [\&Bubba::get_link, 1],
	"get_mtu"				=> [\&Bubba::get_mtu ,0],
	"set_mtu"				=> [\&Bubba::set_mtu ,1],
	"ftp_check_anonymous"	=> [\&Bubba::ftp_check_anonymous ,0],
	"ftp_set_anonymous"		=> [\&Bubba::ftp_set_anonymous ,1],
	'set_samba_interface'	=>  [\&Bubba::set_samba_interface,1],
	# Filemanager
	"dump_file"				=> [\&Bubba::dump_file ,1],
	"ls"					=> [\&Bubba::ls ,2],
	"get_mime"				=> [\&Bubba::get_mime ,1],
	"get_filesize"			=> [\&Bubba::get_filesize ,2],
	"cat"					=> [\&Bubba::cat_file ,2],
	"mv"					=> [\&Bubba::mv ,3],
	"md"					=> [\&Bubba::md ,3],
	"changemod"				=> [\&Bubba::changemod ,3],
	"rm"					=> [\&Bubba::rm ,2],
	"zip_files"				=> [\&Bubba::zip_files ,2],
	# Mail
	"get_mailcfg"			=> [\&Bubba::get_mailcfg ,0],
	"write_send_mailcfg"	=> [\&Bubba::write_send_mailcfg ,5],
	"write_receive_mailcfg"	=> [\&Bubba::write_receive_mailcfg ,1],
	"get_fetchmailaccounts"	=> [\&Bubba::get_fetchmailaccounts ,0],
	"add_fetchmailaccount"	=> [\&Bubba::add_fetchmailaccount ,7],
	"update_fetchmailaccount"	=> [\&Bubba::update_fetchmailaccount ,10],
	"delete_fetchmailaccount"	=> [\&Bubba::delete_fetchmailaccount ,3],
	
	"echo" 					=> [\&Bubba::do_echo,1],
	"update_bubbacfg"		=> [\&Bubba::do_update_bubbacfg,3],
	"get_timezone"		=> [\&Bubba::do_get_timezone,0],
	"set_timezone"		=> [\&Bubba::do_set_timezone,1],

	# notify
	'notify_start' =>  [\&Bubba::notify_start,0],
	'notify_stop' =>  [\&Bubba::notify_stop,0],
	'notify_ack' =>  [\&Bubba::notify_ack,1],
	'notify_flush' =>  [\&Bubba::notify_flush,0],
	'notify_enable' =>  [\&Bubba::notify_enable,2],
	'notify_disable' =>  [\&Bubba::notify_disable,1],

#	""	=> [\& ,],
);

if ((scalar(@ARGV))==0) {
   die "Not enough arguments";
}

my $args=scalar @ARGV-1;
my $cmd=$ARGV[0];

if($commands{$cmd} && $commands{$cmd}[1]==$args){
	$commands{$cmd}[0]->(@ARGV[1..$args])==0 or exit 1;
}else{
	if(!$commands{$cmd}){
		die "Command $cmd not found";
	}else{
		die "Invalid parametercount for command $cmd";
	}
}

