<?php
# Setting the ctype locale to en_US.UTF-8, mostly to enamble escapeshellargs to function properly
setlocale( LC_CTYPE, 'en_US.UTF-8' );
define("DEBUG",0);
define("BUBBA_EASYFIND_CONF","/etc/network/easyfind.conf");
class AdminException extends Exception {

	const MYSQL_CONNECT_ERROR = 0x01;
	const MYSQL_ERROR = 0x02;

	public function __construct($message, $code = 0) {
        parent::__construct($message, $code);
    }
}

function _getlanif(){
	static $lanif="";
	if($lanif==""){
		$lanif=shell_exec("/usr/bin/bubba-networkmanager-cli getlanif");
	}
	return rtrim($lanif);
}

function user_exists($user) {
	$cmd = array('/usr/bin/getent', 'passwd', $user);
	exec( escapeshellargs($cmd), $output, $retval );
	return $retval == 0;
}

# TODO - Fix return values

function uptime(){
   define("MIN",60);
   define("HOUR",MIN*60);
   define("DAY",HOUR*24);
   
   $upt=file("/proc/uptime");
   sscanf($upt[0],"%d",$secs_tot);
   $days=intval($secs_tot/DAY);
   $hours=intval(($secs_tot%DAY)/HOUR);
   $minutes=intval(($secs_tot%HOUR)/MIN);
   $secs=intval($secs_tot%MIN);
   return array($days,$hours,$minutes,$secs);   
}

function get_hdtemp($device){
	$cmd = BACKEND." get_hdtemp $device";
	exec($cmd,$out,$ret);
	
	return $out[0];
}

		
function sizetohuman($val,$unit = 1024){
	$ret="";   							// 1024
	$unit_2 = $unit*$unit;	// 1048576
	$unit_3 = $unit_2 * $unit; // 1073741824
	if($val>=$unit && $val< $unit_2){
		$ret= sprintf("%.1fK",($val/$unit));
	}else if($val>=$unit_2 && $val< $unit_3){
		$ret=sprintf("%.1fM",($val/$unit_2));
	}else if($val>=$unit_3){
		$ret=sprintf("%.1fG",($val/$unit_3));
	}else{
		$ret="$val";
	}
	return $ret;
}


function set_time($time,$date) {
	
	$cmd= BACKEND." set_time \"$date\" \"$time\"";
	exec($cmd,$res_string,$result);	

	return $result;
}

function rm($file,$user) {
	// removes a file from the filesystem

	$file=escapeshellarg($file);
	
	$cmd= BACKEND." rm $file \"$user\"";
	exec($cmd,$res_string,$result);
	return $result;
}
	

function mv($srcfile,$dstfile,$user) {

	$srcfile=escapeshellarg($srcfile);
	$dstfile=escapeshellarg($dstfile);

	$cmd= BACKEND." mv $srcfile $dstfile $user";

	exec($cmd,$out,$result);

	return $result;	
}

function cp($srcfile,$dstfile,$user) {

	$srcfile=escapeshellarg($srcfile);
	$dstfile=escapeshellarg($dstfile);

	$cmd= BACKEND." cp $srcfile $dstfile $user";

	exec($cmd,$out,$result);

	return $result;	
}

function changemod($dest, $mask, $user){

	$dest=escapeshellarg($dest);

	$cmd= BACKEND." changemod $dest 0".decoct($mask)." $user";

	exec($cmd,$out,$result);

	return $result;	
}

function get_filesize($file,$user){

   $file=escapeshellarg($file);

	$cmd = BACKEND." get_filesize $file $user";

	exec($cmd,$out,$ret);

	return $out[0];
}

function cat_file($file, $user) {

   $file=escapeshellarg($file);

	passthru(BACKEND." cat $file \"$user\"",$ret);
	
	return $ret;
}

function get_mime($file) {
	
   $file=escapeshellarg($file);
	$cmd=BACKEND." get_mime $file";
	exec($cmd,$out,$ret);
	
	return $out[0];
}

function stat_file($file) {

	$file=escapeshellarg($file);
	$cmd=BACKEND." get_mime $file";	
	exec($cmd,$out,$ret);

	return $ret;
}

function zip_files($files, $prefix, $user){

   $descriptorspec = array(
      0 => array("pipe", "r"),  // stdin
      1 => array("pipe", "w")   // stdout
   );

   $pref2=escapeshellarg($prefix);

	$cmd=BACKEND." zip_files $pref2 \"$user\"";	
   $process = proc_open($cmd, $descriptorspec, $pipes);

   if(is_resource($process)){
      foreach($files as $file){
         $line=$file;         
         fwrite($pipes[0],$line."\n");
      }
      fclose($pipes[0]);
      
      $out=fopen("php://output",'w');      
      while (!feof($pipes[1])) {
        fwrite($out,fread($pipes[1], 8192));
      }
      fclose($out);
      fclose($pipes[1]);
   }

}

function ls($uname, $path){

   $path=escapeshellarg($path);
   $cmd=BACKEND." ls $uname $path";

   exec($cmd,$out,$ret);
   if($ret!=0){
      return "\0\0";   
   }else{   
      return $out;
   }
}

function get_easyfind() {
  
  $retval = array("",0,"");
	if(file_exists(BUBBA_EASYFIND_CONF)) {
		$arr = file(BUBBA_EASYFIND_CONF);
		foreach($arr as $line){
			$line=trim($line);
	
			if($line==""){
				continue;
			}
			if($line[0]=='#' || $line[0]==';'){
					continue;
			}	
			if(preg_match("/^enable\s*=\s*yes/i",$line)) {
			  $retval[0] = "checked";
			}
			
			if(preg_match("/^ip\s*=\s*([\d\.]*)/i",$line,$matches)){
			  $retval[1] = $matches[1];
			}
			if(preg_match("/^name\s*=\s*(.*)$/i",$line,$matches)){
			  $retval[2] = $matches[1];
			}
			
		}
	}
	if (!$retval[2]) {
		if($retval[0]) {
    	$cmd=BACKEND." easyfind getname 0";
		  exec($cmd,$out,$ret);
		  if(sizeof($out)) {
		  	$retval[2] = $out[0];
		  } else {
			  $retval[2] = "No name set";
			}
	  } else {
		  $retval[2] = "";
		}
	}
	return $retval;
   
}

function enable_easyfind($enable) {
  
  if($enable) {
		$cmd=BACKEND." easyfind enable 0";
		exec($cmd,$out,$res);
	} else {
		$cmd=BACKEND." easyfind disable 0";
		exec($cmd,$out,$res);
	}
}

function setname_easyfind($name) {

	$cmd=BACKEND." easyfind setname $name";
	exec($cmd,$out,$res);
	$res = implode("\n",$out);
	if(preg_match("/Name updated/",$res)) {
		return 1;
	} else {
		return 0;
	}
}

function get_workgroup(){
	$arr=file("/etc/samba/smb.conf");
	$wg="";	
	foreach($arr as $line){
		$line=trim($line);
		
		if($line==""){
			continue;
		}
		if($line[0]=='#' || $line[0]==';'){
				continue;
		}	

		if(preg_match("/^workgroup\s*=\s*([\w-]*)$/i",$line,$matches)){
			$wg=$matches[1];
			break;
		}
	}
	return $wg;
}

function set_workgroup($workgroup){
   
    $cmd=BACKEND." set_workgroup $workgroup";

    $result=shell_exec($cmd);   
}

function set_unix_password($uname, $pwd){

    $cmd=BACKEND." set_unix_password $uname '$pwd'";

    $result=shell_exec($cmd);

}

function set_samba_password($uname, $pwd1, $pwd2){

	$cmd=BACKEND." set_samba_password $uname '$pwd1' '$pwd2'";
	$result=shell_exec($cmd);
}

function del_user($uname){
	
	$cmd=BACKEND." del_user $uname";
	exec($cmd,$out,$res);
	return $res;
}


function purge_horde($uname){
	require_once('/etc/horde/debian-db.php');
	$db = new mysqli( $dbserver ? $dbserver : null , $dbuser, $dbpass, $dbname, $dbport ? $dbport : null );

	if( $db->connect_error ) {
		throw new AdminException(mysqli_connect_error(), AdminException::MYSQL_CONNECT_ERROR );
	}

	$uname = $db->escape_string($uname);

	$queries = array(
		"DELETE FROM horde_prefs WHERE pref_uid='$uname'",
		"DELETE FROM kronolith_events WHERE calendar_id='$uname'",
		"DELETE FROM mnemo_memos WHERE memo_owner='$uname'",
		"DELETE FROM turba_objects WHERE owner_id='$uname'",
		#		"DELETE FROM nag_tasks WHERE task_owner='$uname'",
		"DELETE FROM horde_datatree WHERE user_uid='$uname'"
	);

	$result = $db->query("SELECT datatree_id FROM horde_datatree WHERE user_uid='$uname'");
	if( !$result ) {
		throw new AdminException($db->error, AdminException::MYSQL_ERROR);
	}
	$datatree_ids = array();

	while( $row = $result->fetch_row() ) {
		$datatree_ids[] = "datatree_id='$row[0]'";
	}

	$result->free();
 
	$datatree_ids = implode(" OR ", $datatree_ids );

	$queries[] = "DELETE FROM horde_datatree_attributes WHERE $datatree_ids";

	$queries = implode( ';', $queries );

	if( $db->multi_query( $queries ) ) {
		do {
			if( $result = $db->store_result() ) {
				$result->free_result();
			} elseif( $db->errno != 0 ) {
				throw new AdminException($db->error, AdminException::MYSQL_ERROR);
			}
		} while( $db->next_result() );
		if( $db->more_results() ) {
			throw new AdminException($db->error, AdminException::MYSQL_ERROR);
		}
	} else {
		throw new AdminException($db->error, AdminException::MYSQL_ERROR);
	}

	$db->close();

}

function update_user($realname,$shell,$uname){
	
	$cmd = BACKEND." update_user '$realname' $shell $uname";
	exec($cmd,$out,$res);
	
	return $res;
}

function add_user($realname,$group,$shell,$pass1,$uname){
	
	$cmd = BACKEND." add_user '$realname' $group $shell $pass1 $uname";
	exec($cmd,$out,$res);
	return $res;
}

function power_off(){
	
	$cmd = BACKEND." power_off";
	exec($cmd,$out,$res);
	return $res;
}

function reboot(){
	
	$cmd = BACKEND." reboot";
	exec($cmd,$out,$res);
	return $res;
}

function change_hostname($hostname){

	$cmd=BACKEND." change_hostname $hostname";
	exec($cmd,$out,$res);
	return $res;
}

function restart_avahi() {
	_system(BACKEND, 'restart_avahi');
}

function restart_samba(){
	
	$cmd=BACKEND." restart_samba";
	$result=shell_exec($cmd);
}

function reload_samba(){
	
	$cmd=BACKEND." reload_samba";
	$result=shell_exec($cmd);
}


function dump_file($filename){

	$filename=escapeshellarg($filename);
	$cmd=BACKEND."  dump_file $filename ";
	exec($cmd,$out,$ret);

	return $out;
}

function restart_network($interface){
   
	$cmd=BACKEND." restart_network $interface";
	$result=shell_exec($cmd);
	if(query_service("proftpd")) {
		stop_service("proftpd");
		start_service("proftpd");	
	}
	if( strcmp($interface,_getlanif()) == 0 ) {
		if(query_service("avahi-daemon")){
			stop_service("avahi-daemon");
			start_service("avahi-daemon");
		}
		if(query_service("samba")){
			restart_samba();
		}
		if(query_service("mt-daapd")){
			stop_service("mt-daapd");
			sleep(1);
			start_service("mt-daapd");
		}  
		if(query_service("mediatomb")){
			stop_service("mediatomb");
			start_service("mediatomb");
		}
	}
}

function get_interface_info($iface){
	$res=array();
	exec("/sbin/ifconfig $iface",$out,$ret);
	foreach($out as $line){
		if(preg_match("/inet addr:([\d.]+)/",$line,$match)){
			$res[0]=$match[1];
		}
		if(preg_match("/Mask:([\d.]+)/",$line,$match)){
			$res[1]=$match[1];
		}
	}
	return $res;
}

function get_route(){
	$res="";
	exec("/sbin/route -n",$out,$ret);
	foreach($out as $line){
		if(preg_match("/^0\.0\.0\.0\s+([\d.]+)/",$line,$match)){
			$res=$match[1];
			break;
		}
	}
	return $res;
}

function get_dns(){
	$res=array();

	$dns=file("/etc/resolv.conf");
	foreach($dns as $line){
		if(preg_match("/nameserver\s+([\d.]+)/",$line,$match)){
			$res[]=$match[1];
			break;
		}
	}
	return $res;
}

function _check_dhcp($iface=""){
	if($iface=""){
		$iface=_getlanif();
	}
	$cdhcp=false;
	$netcfg=file("/etc/network/interfaces");
	foreach ($netcfg as $i) {
		$trim_line = trim($i);
		$pieces = explode(" ",$trim_line);
		if(count($pieces)==4){
			if($pieces[1]==$iface && $pieces[3]=="dhcp"){
				$cdhcp=true;
				break;
			}
		}
	}
	return $cdhcp;
}

function get_networkconfig($iface="eth0"){
	$res=array();
	$res[0] = "...";  // set default values to IP-adress
	$res[1] = "...";
	$res["dhcp"] = false;

	if(!$res["dhcp"]=_check_dhcp($iface)) {
		$cmd=BACKEND." get_interfaces";
		exec($cmd,$out,$ret);
		foreach($out as $line) {
			unset($args);
			$vals = explode(" ",$line);
			foreach($vals as $arg) {  // inside one line
				list($key,$value) = explode("=",$arg,2);
				$args[$key] = $value;
			}
			if(!strcmp($args["IF"],$iface)) {
				if(!strcmp($args["mode"],"dhcp")) {
					$res["dhcp"] = true;
				} else {
					$res["dhcp"] = false;
					$res[0] = $args["addr"];
					$res[1] = $args["mask"];
				}
			}			
		}
	} else { // default
		exec("/sbin/ifconfig $iface",$out,$ret);
		foreach($out as $line){
			if(preg_match("/inet addr:([\d.]+)/",$line,$match)){
				$res[0]=$match[1];
			}
			if(preg_match("/Mask:([\d.]+)/",$line,$match)){
				$res[1]=$match[1];
			}
		}
	}
	exec("/sbin/route -n",$out,$ret);
	$res[2]="0.0.0.0";
	foreach($out as $line){
		if(preg_match("/^0\.0\.0\.0\s+([\d.]+)/",$line,$match)){
			$res[2]=$match[1];
			break;
		}
	}

	$dns=file("/etc/resolv.conf");
	$res[3]="0.0.0.0"; 
	foreach($dns as $line){
		if(preg_match("/nameserver\s+([\d.]+)/",$line,$match)){
			$res[3]=$match[1];
			break;
		}
	}
	return $res;	
	
}

function set_static_netcfg($iface, $ip,$nm,$gw){
   
   $cmd=BACKEND." set_static_netcfg $iface $ip $nm $gw";
   exec($cmd,$out,$ret);
   return $ret;
}

function set_nameserver($ns){
   $cmd=BACKEND." set_nameserver $ns";
   exec($cmd,$out,$ret);
   return $ret;
}

function set_dynamic_netcfg($iface){
   
   $cmd=BACKEND." set_dynamic_netcfg $iface";
   exec($cmd,$out,$ret);
   // Does this succeed, do we gen an IP?
   return $ret;

}

function service_running($service){
   
   $cmd=BACKEND." service_running $service";

   exec($cmd,$out,$ret);
   return $ret == 1;   
}

function start_service($name){
   
	$cmd=BACKEND." start_service $name";
	$result=shell_exec($cmd);

}

function stop_service($name){
   
   $cmd=BACKEND." stop_service $name";
	$result=shell_exec($cmd);

}

function add_service($name, $level=0){
   
	if($level==0){
		$cmd=BACKEND." add_service $name";
	}else{
		$cmd=BACKEND." add_service_at_level $name $level";
	}

	$result=shell_exec($cmd);
}


function remove_service($name){
   
	$cmd=BACKEND." remove_service $name";
	$result=shell_exec($cmd);
}

function query_service($name){

   $res=glob("/etc/rc2.d/S??$name");
   return $res?true:false;

}

function is_installed($package) {
	$cmd=BACKEND." package_is_installed $package";
	return shell_exec($cmd);
}

function get_mailcfg(){
   
   $cmd=BACKEND." get_mailcfg";
   
   exec($cmd,$out,$ret);
   return $out;

}

function write_send_mailcfg($mailhost, $auth, $user,$passwd, $plain_auth){

	$auth=$auth?"yes":"no";
	$plain_auth=$plain_auth?"yes":"no";

   
   $cmd=BACKEND." write_send_mailcfg \"$mailhost\" \"$auth\" \"$user\" \"$passwd\" \"$plain_auth\"";
   
   exec($cmd,$out,$ret);
   return $ret;

}

function write_receive_mailcfg($domain){
   
   $cmd=BACKEND." write_receive_mailcfg \"$domain\"";
   
   exec($cmd,$out,$ret);
   return $ret;

}

function write_mailcfg($mailhost, $domain){
   
   $cmd=BACKEND." write_mailcfg \"$mailhost\" \"$domain\"";
   
   exec($cmd,$out,$ret);
   return $ret;

}

function get_fetchmailaccounts(){
   
   $cmd=BACKEND." get_fetchmailaccounts";
   exec($cmd,$out,$ret);
   return $out;

}

function add_fetchmailaccount($host, $proto, $ruser, $pwd, $luser, $ssl, $keep){
   
   $cmd=BACKEND." add_fetchmailaccount $host $proto $ruser $pwd $luser $ssl $keep";
   
   exec($cmd,$out,$ret);
   return $ret;

}

function update_fetchmailaccount($o_host, $o_proto, $o_ruser,$host, $proto, $ruser, $pwd, $luser, $ssl,$keep){
   
   _system(BACKEND." update_fetchmailaccount",$o_host, $o_proto, $o_ruser, $host, $proto, $ruser, $pwd, $luser, $ssl, $keep);
   return 0;

}

function delete_fetchmailaccount($host, $proto, $ruser){
   
   $cmd=BACKEND." delete_fetchmailaccount $host $proto $ruser";
   
   exec($cmd,$out,$ret);
   return $ret;

}

function ftp_check_anonymous(){
   
   $cmd=BACKEND." ftp_check_anonymous";
   
   exec($cmd,$out,$ret);
   return $ret;
}

function ftp_set_anonymous($status){
   
   $cmd=BACKEND." ftp_set_anonymous $status";
   
   exec($cmd,$out,$ret);
   return $ret;
}
/*
	// Todo: Is this uses at all?
function check_mountpath($path){
	$cmd=DISK." check_mountpath \"$path\"";
	exec($cmd,$out,$ret);
	return $out[0];
}

function user_mount($dev,$path,$fstype){
	$cmd=DISK." user_mount $dev $path \"$fstype\"";
	exec($cmd,$out,$ret);
	return $ret;
}

function user_umount($dev){
	$cmd=DISK." user_umount $dev";

	exec($cmd,$out,$ret);
	return $ret;
}

function list_disks(){
	$cmd=DISK." list_devices";

	exec($cmd,$out,$ret);
	$res=array();
	foreach( $out as $line){
		list($device,$status,$path,$model,$vendor)=split(":",$line,5);
		$res[]=array(
			"device" => $device,
			"status" => $status,
			"path" => $path,
			"model" => $model,
			"vendor" => $vendor);
	}

	return $res;
}
*/
function get_attached_printers(){
   
   $cmd=PRINTFS." get_attached_printers";
   
   exec($cmd,$out,$ret);
   return $out;
}

function get_installed_printers(){
   
   $cmd=PRINTFS." get_installed_printers";
   
   exec($cmd,$out,$ret);
   $res=array();
   foreach( $out as $line){
		list($name,$key,$value)=split(" ",$line,3);
		$res[$name][$key]=$value;
   }
   
   return $res;
}
function add_printer($name, $url, $info, $loc){
   
   $cmd=PRINTFS." add_printer \"$name\" $url \"$info\" \"$loc\"";
   
   exec($cmd,$out,$ret);
   reload_samba();   
   return $ret;
}

function delete_printer($name){
   
   $cmd=PRINTFS." delete_printer \"$name\"";
   
   exec($cmd,$out,$ret);
   reload_samba();
   return $ret;
}

function set_default_printer($name){
   
   $cmd=PRINTFS." set_default_printer \"$name\"";
   
   exec($cmd,$out,$ret);
   return $ret;
}

function get_default_printer(){
   
   $cmd=PRINTFS." get_default_printer";
   
   exec($cmd,$out,$ret);
   return $out;
}

function enable_printer($name){
   
   $cmd=PRINTFS." enable_printer \"$name\"";
   
   exec($cmd,$out,$ret);
   return $ret;
}

function disable_printer($name){
   
   $cmd=PRINTFS." disable_printer \"$name\"";
   
   exec($cmd,$out,$ret);
   return $ret;
}

function backup_config($path) {
   
   $path=escapeshellarg($path);

	$cmd=(BACKEND." backup_config $path");
	
	exec($cmd,$out,$ret);
   	return $ret;
}

function restore_config($path){

	$path=escapeshellarg($path);
	$cmd=BACKEND." restore_config $path";
   
	exec($cmd,$out,$ret);
	return $ret;
}
/*
function mount($device, $path, $type){

	$path=escapeshellarg($path);
	$cmd=BACKEND." mount $device $path \"$type\"";
   
	exec($cmd,$out,$ret);
	return $ret;
}

function umount($path){

	$path=escapeshellarg($path);
	$cmd=BACKEND." umount $path";
   
	exec($cmd,$out,$ret);
	return $ret;
}
*/

function md($directory,$mask,$user){

	$directory=escapeshellarg($directory);
	$cmd=BACKEND." md $directory $mask $user";
   
	exec($cmd,$out,$ret);
	return $ret;
}   

function b_enc($a,$tick=False){
   if($tick){
      $a=str_replace("'","\'",$a);
   }
   return rawurlencode($a);
}

function b_dec($a){
   return rawurldecode($a);
}

function get_lanclients() {
	$dnsmasq_leases = "/var/lib/dnsmasq/dnsmasq.leases";

	if( !file_exists($dnsmasq_leases) ) {
		return array();
	}	
	$clients = array();
	$cmd = BACKEND . " dump_file $dnsmasq_leases";
	exec( $cmd, $out, $ret );
	foreach( $out as $value ) {
		list( $timestamp, $mac, $ip, $name, $a_star ) = explode( ' ', $value );
		$cur = array(
			'mac' => $mac,
			'ip' => $ip,
			'dns' => $name
			);
		array_push( $clients, $cur );
	}
	return $clients;
}

function get_fwsettings() {
 
	$iptable = array();
	
	$cmd = FIREWALL." listrules";
	exec($cmd,$out,$ret);
	foreach($out as $value) {
		$vars = explode("\t",$value);
		foreach($vars as $args) {
			list($key,$val)=explode("=",$args);
			$rule[$key] = $val;
		}
		$iptable[$rule["chain"]][$rule["dport"].$rule["protocol"]]=$rule;
	}
	$retval["allowWWW"]=false;
	$retval["allowSSH"]=false;
	$retval["allowFTP"]=false;
	$retval["allowAdmin"]=false;
	$retval["allowPing"]=false;
	$retval["allowMail"]=false;
	$retval["allowIMAP"]=false;
	$retval["allowTorrent"]=false;

	if(isset($iptable["INPUT"]["21tcp"]))
		if(!strcmp($iptable["INPUT"]["21tcp"]["target"],"ACCEPT")) {
			$iptable["INPUT"]["21tcp"] = 0;
			$retval["allowFTP"]=true;
		}

	if(isset($iptable["INPUT"]["22tcp"]))
		if(!strcmp($iptable["INPUT"]["22tcp"]["target"],"ACCEPT")){
			$iptable["INPUT"]["22tcp"] = 0;
			$retval["allowSSH"]=true;
		}

	if(isset($iptable["INPUT"]["80tcp"]))
		if(!strcmp($iptable["INPUT"]["80tcp"]["target"],"ACCEPT")){
			$iptable["INPUT"]["80tcp"] = 0;
			$iptable["INPUT"]["443tcp"] = 0;
			$retval["allowWWW"]=true;
		}

	if(isset($iptable["INPUT"]["25tcp"]))
		if(!strcmp($iptable["INPUT"]["25tcp"]["target"],"ACCEPT")){
			$iptable["INPUT"]["25tcp"] = 0;
			$retval["allowMail"]=true;
		}

	if(isset($iptable["INPUT"]["143tcp"]))
		if(!strcmp($iptable["INPUT"]["143tcp"]["target"],"ACCEPT")){
			$iptable["INPUT"]["143tcp"] = 0;
			$iptable["INPUT"]["993tcp"] = 0;
			$retval["allowIMAP"]=true;
		}

	if(isset($iptable["INPUT"]["pingicmp"]))
		if(!strcmp($iptable["INPUT"]["pingicmp"]["target"],"ACCEPT")){
			$iptable["INPUT"]["pingicmp"] = 0;
			$retval["allowPing"]=true;
		}

	if(isset($iptable["INPUT"]["10000:14000tcp"]))
		if(!strcmp($iptable["INPUT"]["10000:14000tcp"]["target"],"ACCEPT")){
			$iptable["INPUT"]["10000:14000tcp"] = 0;
			$retval["allowTorrent"]=true;
		}

	$retval['fwports'] = array();
	if(isset($iptable["INPUT"])) {
		foreach($iptable["INPUT"] as $key => $rule) {
			if (!strcmp($rule["target"],"ACCEPT")) {
				$retval["fwports"][$key]=$rule;
				if(!isset($retval["fwports"][$key]["to_ip"])) {
					$retval["fwports"][$key]["to_ip"] =  t("Bubba|Two");
				}
				if(!isset($retval["fwports"][$key]["to_port"])) {
					$retval["fwports"][$key]["to_port"] = "";
				}
				$retval["fwports"][$key]["enabled"]=1;
			}
		}
	}
  
	if(isset($iptable["PREROUTING"])) {
		foreach($iptable["PREROUTING"] as $key => $rule) {
			//if($rule["source"]=="0.0.0.0/0") {
			//	$rule["source"]="all";
			//}
			if (!strcmp($rule["target"],"DNAT")) {
				$retval["fwports"][$key]=$rule;
				$retval["fwports"][$key]["enabled"]=1;
			}
			if (!strcmp($rule["target"],"DISABLED")) {
				$retval["fwports"][$key]=$rule;
				$retval["fwports"][$key]["enabled"]=0;
			}
		}
	}

	return $retval;

}


function rm_portforward($rule) {

	$cmd = FIREWALL." rm_portforward $rule[dport] $rule[protocol] $rule[source] $rule[to_ip] $rule[to_port]";
	exec($cmd,$out,$ret);
	return $out;
	
}

function add_portforward($portdata) {

	$cmd = FIREWALL." add_portforward ";
	$cmd .= " $portdata[dport] $portdata[protocol] $portdata[source] $portdata[to_ip] $portdata[to_port] $portdata[netmask] $portdata[serverip]";
	//$cmd .= sprintf("%s %s %s %s %s",$portdata['dport'],$portdata['protocol'],$portdata['source'],$portdata['to_ip'],$portdata['to_port']);
	exec($cmd,$out,$ret);

	return $out;

}

function open_port($port) {

	$cmd = FIREWALL." openport $port[dport] $port[protocol] $port[source] filter INPUT";
	exec($cmd,$out,$ret);
	return $out;
}

function close_port($port) {

	$cmd = FIREWALL." closeport $port[dport] $port[protocol] $port[source] filter INPUT";
	exec($cmd,$out,$ret);
	return $out;
}

function fw_updateservices($portlist) {

	foreach($portlist as $port => $open) {
		if($open) { // OPEN ports
			if (!strcmp($port,"ping"))
				$cmd = FIREWALL." openport 8 icmp 0 filter INPUT";
			else 
				$cmd = FIREWALL." openport $port tcp 0 filter INPUT";
			exec($cmd,$out,$ret);
		  	
			// Additional related ports (mainly encrypted traffic ports
			if ($port == 80) {
				$cmd = FIREWALL." openport 443 tcp 0 filter INPUT";
				exec($cmd,$out,$ret);
			}
			if ($port == 143) {
				$cmd = FIREWALL." openport 993 tcp 0 filter INPUT";
				exec($cmd,$out,$ret);
			}
			unset($out); // exec seems to append to $out.
	
		} else { // Close ports
	
			if (!strcmp($port,"ping"))
				$cmd = FIREWALL." closeport 8 icmp 0 filter INPUT";
			else 
				$cmd = FIREWALL." closeport $port tcp 0 filter INPUT";
			exec($cmd,$out,$ret);
			if ($port == 80) {
				$cmd = FIREWALL." closeport 443 tcp 0 filter INPUT";
				exec($cmd,$out,$ret);
			}
			if ($port == 143) {
				$cmd = FIREWALL." closeport 993 tcp 0 filter INPUT";
				exec($cmd,$out,$ret);
			}
			unset($out); // exec seems to append to $out.
		}		
	}
			
	return 1;
	
}

function get_dnsmasq_settings() {

	$dhcpd["running"]=service_running("dnsmasq");
	$dhcpd["range_start"]="n/a";
	$dhcpd["range_end"]="n/a";
	$dhcpd["netmask"]="n/a";
	$dhcpd["leasetime"]="n/a";

	$conf_file="/etc/dnsmasq.conf";
	if (file_exists($conf_file)) {
		$arr = file($conf_file);
		$lanif=_getlanif();

		$dhcpd["dhcpd"]=true; // will be changed if there is a "no-dhcp-interface" option below.
		
		foreach($arr as $line){
			$line=trim($line);

			if($line==""){
				continue;
			}
			if($line[0]=='#' || $line[0]==';'){
				continue;
			}	

			if(preg_match("/^\s*interface\s*=\s*(.*)$/i",$line,$matches)){
				$dhcpd["interface"]=$matches[1];
			}

			if(preg_match("/^\s*dhcp-range\s*=\s*([\d\w\.,-]*)$/i",$line,$matches)){
				$range_vals = explode(",",$matches[1]);				

				$range_offset=0;
				$lease_offset=0;
				if(preg_match("/([a-z,A-Z])+/i",$range_vals[0])) {
					$range_offset=1;
				}
				if(preg_match("/[hms]+/",$range_vals[1+$range_offset]))
					$lease_offset=1;

				$dhcpd["range_start"]=explode(".",$range_vals[0+$range_offset]);
				$dhcpd["range_end"]=explode(".",$range_vals[1+$range_offset]);
				if($lease_offset)
					$dhcpd["netmask"]=$range_vals[2+$range_offset];
				$dhcpd["leasetime"]=$range_vals[2+$range_offset+$lease_offset];

			}

			if(preg_match("/^\s*no-dhcp-interface\s*=\s*".$lanif."\s*$/i",$line,$matches)) {
				$dhcpd["dhcpd"]=false;
			}

		}
	}
	return $dhcpd;	
}

function get_leases() {

	$lease_file="/var/lib/dnsmasq/dnsmasq.leases";
	$leases = array	();
	if (file_exists($lease_file)) {
		$arr = file($lease_file);
		foreach($arr as $line){
			$values = explode(" ",$line);
			$leases[$values[1]]["exp_time"] = $values[0];
			$leases[$values[1]]["ip"] = $values[2];
			$leases[$values[1]]["hostname"] = $values[3];
			$leases[$values[1]]["client-id"] = $values[4];

		}
	}
	return $leases;
}

function configure_dnsmasq($dnsmasq) {
	// returns an array ($retval) with "errors" with what was wrong.

	$retval = array("dns" => false, "dhcpd" => false, "dhcpdrange" => false);	
		 
	$odnsmasq = get_dnsmasq_settings();
	$ostart = implode(".",$odnsmasq["range_start"]);
	$oend = implode(".",$odnsmasq["range_end"]);
	$new_range = false;
	$start = $ostart;
	$end = $oend;
	
	if(isset($dnsmasq["dhcpd"])) {
		$start = implode(".",$dnsmasq["range_start"]);
		$end = implode(".",$dnsmasq["range_end"]);
		$new_range = strcmp($start,$ostart) || strcmp($end,$oend);
	} else {
		$dnsmasq["dhcpd"]= false;
	}
	
	if(!isset($dnsmasq["interface"])){
		$dnsmasq["interface"]=$odnsmasq["interface"];
	}
	
	if ( ( $odnsmasq["dhcpd"] != $dnsmasq["dhcpd"] )|| $odnsmasq["interface"] != $dnsmasq["interface"] || $new_range ) {
		if($dnsmasq["dhcpd"])
			$dhcpd_on = "1";
		else
			$dhcpd_on = "0";
		
		$cmd = BACKEND." dnsmasq_config $dhcpd_on $start $end ".$dnsmasq['interface'];
		exec($cmd,$out,$ret);			
	}
	
	// start/remove/restart?
	if(isset($dnsmasq["running"]) && $dnsmasq["running"]) {
		if (service_running("dnsmasq")) {
			// service already running, check if it is in the startscripts.
			if(!query_service("dnsmasq")) {
				// not there, probably started by dhcp fallback script. Add it.
				add_service("dnsmasq");
			}
			// restart
			stop_service("dnsmasq");
			start_service("dnsmasq");
		} else {
			// start service
			add_service("dnsmasq");
			start_service("dnsmasq");
			$retval["dns"] != service_running("dnsmasq");
		}
	} else {
		if(service_running("dnsmasq")) {
			// stop serivce
			stop_service("dnsmasq");
			remove_service("dnsmasq");
			$retval["dns"] = service_running("dnsmasq");
		} else {
			// do nothing, service is not running
		}
	}

	return $retval;			
}

function get_package_version($package="bubba-frontend") {
	
	$cmd = BACKEND." get_version " . escapeshellarg($package);
	exec($cmd,$out,$ret);
	$data = implode("\n",$out);
	$a_package = split(" ",$package);
	
	if(sizeof($a_package)>1) {
		foreach($a_package as $name) {
			preg_match("/$name\s*([\d\w\.\-\+]+)\s/",$data,$matches);
			$versions[$name] = $matches[1];
		}
		return $versions;
	} else {			
		preg_match("/$package\s*([\d\w\.\-\+]+)\s/",$data,$matches);
		return $matches[1];	
	}
}

function update_bubbacfg($user,$param,$value) {

	$param = escapeshellarg($param);
	$value = is_bool($value) ? $value ? 'yes' : 'no' : escapeshellarg($value);

	$cmd=(BACKEND." update_bubbacfg $user $param $value");

	exec($cmd,$out,$ret);
	return $ret;
}

function query_bubbacfg( $user, $param ) {
	$cfg_file = "/home/$user/.bubbacfg";
	if( file_exists( $cfg_file ) && is_readable( $cfg_file ) ) {
		$conf = parse_ini_file( $cfg_file );
		if( isset( $conf[$param] ) ) {
			return $conf[$param];
		} else {
			return null;
		}
	} else {
		return null;
	}
}

function get_mtu(){
	$cmd=BACKEND." get_mtu";
   
	exec($cmd,$out,$ret);
	return $out[0];
}

function set_mtu($mtu){
	$cmd=BACKEND." set_mtu $mtu";
   
	exec($cmd,$out,$ret);
	return $ret;
}

function d_print_r($var_to_print) {
  if(DEBUG) {
    print("<pre>");
    print_r($var_to_print);
    print("</pre>");
  }
}

function exit_wizard() {
	unset($_SESSION['run_wizard']);
	update_bubbacfg($_SESSION['user'],'run_wizard',"no");
}

function start_wizard() {
	$_SESSION['run_wizard'] = true;
}

function get_timezone_info() {
	
	$zoneinfo = '/usr/share/zoneinfo/right';
	if ($h_zonebase = opendir($zoneinfo)) {
		
		$zones = array();
		$zones['other'] = array();
		/* This is the correct way to loop over the directory. */
		while (false !== ($file = readdir($h_zonebase))) {
			if(!($file === "." || $file === ".." || $file ==="SystemV")){
				if(is_dir($zoneinfo ."/". $file)) {
					$zones[$file] = array();
					if ($h_regions = opendir($zoneinfo."/".$file)) {
						while (false !== ($r_name = readdir($h_regions))) {
							if(!($r_name === "." || $r_name === "..")){
								array_push($zones[$file],$r_name);
							}
						}
						sort($zones[$file]);
						closedir($h_regions);
					}
				} else {
					array_push($zones['other'],$file);
				}
			}
		}
		ksort($zones);
		sort($zones['other']);
		closedir($h_zonebase);
	}
	return $zones;
}

function get_current_tz() {
	
	$cmd=BACKEND." get_timezone";
	exec($cmd,$out,$ret);
	return $out[0];
}
function set_timezone($tz) {
	
	$cmd=BACKEND." set_timezone $tz";
	exec($cmd,$out,$ret);
	return $out[0];
}

function get_backupjobs($user) {
	
	$cmd = BACKUP." listjobs $user";
	exec($cmd,$out,$ret);
	return $out;
}
function get_backupsettings($user,$jobname) {
	
	$jobdata = "/home/".$user."/.backup/".$jobname."/jobdata";
	if(file_exists($jobdata)) {
		return parse_ini_file($jobdata);
	} else {
		return array();
	}
	
}


function write_backupsettings($user,$settings) {
	// this should be moved to backup backend
	
	$filepath = "/home/" . $user ."/.backup/".$settings['jobname'] ."/jobdata";
	$fh = fopen($filepath,'w'); 
	fwrite($fh,"local_user = $user\n");
	foreach($settings as $key => $value) {
		fwrite($fh,"$key = $value\n");
	}
	fclose($fh);
}

function write_backupschedule($user,$jobname,$schedule) {
	
	$cmd = BACKUP." writeschedule $user $jobname '$schedule'";
	exec($cmd,$out,$ret);
	if(isset($out[0])) {
		return preg_match("/Error/i",$out[0]);
	} else {
		return 0;
	}

}


function backup_updatesettings($user,$data) {
	
	$error = "";

	// set "default schedule" to '* * * * *'
	$schedule["minute"] = "0";
	$schedule["hour"] = "*";
	$schedule["dayofmonth"] = "*";
	$schedule["month"] = "*";
	$schedule["weekday"] = ""; // do not set weekday here since it will be checked and set later.

	// check that all required fields are present
	$req_fields = array("current_job","target_protocol");
		
	foreach($req_fields as $field) {
		if(!isset($_POST[$field]) || $_POST[$field] == "") {
			$error .= t("Required field") ." ". t($field) . " " .t("is missing");
		}
	}

	// encryption requires password.
	if(isset($_POST['encrypt'])) {
		if(!isset($_POST['GPG_key']) || $_POST['GPG_key'] == "") {
			$error .= " " . t("Encryption selected, but no password entered");
		}
	}
		
	if(isset($_POST['target_protocol'])) {
		if($_POST['target_protocol'] == "file") {
			// require disk label and disk uuid
			if(! (isset($_POST["disk_label"]) && isset($_POST["disk_uuid"])) ) {
				$error .= " " . t("No external disk selected");
			}
		} else {
			// require remote host and password
			if(!isset($_POST["target_host"]) || $_POST["target_host"] == "" ) {
				$error .= " " . t("Host target missing");
			}
			if(!(isset($_POST["target_user"]) && isset($_POST["target_FTPpasswd"])) || $_POST["target_FTPpasswd"] =="" || $_POST["target_user"] == "" ) {
				$error .= " " . t("Target settings (user/password) missing");
			}
		}
	}
	
	if(!$error) {
		foreach($_POST as $key => $value) {
			// filter keys
			switch ($key) {
				case "current_job"       :
					$settings["jobname"] = $value;
					break;
				case "target_protocol"   :
					if($value == "file") {
						$settings["disk_label"] = $_POST["disk_label"][$_POST["disk_uuid"]];
					}
				case "target_path"       :
				case "target_user"       :
				case "monthweek"         :

					if(preg_match("/[^\w\_\-\/]/",$value,$chars)) {  // only allow "\w", "_", "-", "/" 
						//print "Error in $key: $value\n";
						$error .= t("Illegal character(s) '$chars[0]' in field: ");
						switch ($key) {
							case "target_path" : 
								$error .= t("'Destination directory'");
								break;
							case "target_user" : 
								$error .= t("'Remote user'");
								break;
							case "monthweek" : 
								$error .= t("schedule settings");
								break;
							default:
								$error .= $key;
								break;
						}
					} else {
						$settings[$key] = $value;
					}
					break;
				case "target_host"       :
					if(preg_match("/[^\w\.]/",$value,$chars)) {  // only allow "\w", "." 
					  $error .= t("Illegal character(s) '$chars[0]' in field: 'Target'");
					} else {
						$settings[$key] = $value;
					}
					break;
					
				case "encrypt"           :
				case "GPG_key"           :
					// how do we verify this?
					// or more accurate, how do we escape it.
				case "target_FTPpasswd"  :
					// how do we verify this?
					// or more accurate, how do we escape it.
					$settings[$key] = $value;
					break;
					
				case "nbr_fullbackups"   :
					if(preg_match("/[^\d]/",$value)) {
						$error .= "$key ";
					} else {
						$settings[$key] = $value;
					}
					break;
					
				case "full_expiretime"   :
					if(preg_match("/[^01DWM]/",$value)) {
						$error .= "$key ";
						
					} else {
						$settings[$key] = $value;
					}
					break;
	
				case "timeofday"   : // 0-23
					if(preg_match("/[^\d]/",$value)) {
						$error .= "$key ";
						
					} else {
						$settings[$key] = $value;
					}
					$schedule["hour"] = $value;
					break;
				case "hourly"   :			// 1,2,6,12
					if(preg_match("/[^\d]/",$value)) {
						$error .= "$key ";
						
					} else {
						$settings[$key] = $value;
					}
					if($value == 1) {
						$schedule["hour"] = "*";
					} else {
						$schedule["hour"] = "*/$value";
					}
					break;
	
				case "dayofmonth"   : // 1-31
					$schedule["dayofmonth"] = $value;
					break;
	
				case "mon":
				case "tue":
				case "wed":
				case "thu":
				case "fri":
				case "sat":
				case "sun":
					if($key <> $value) {
						$error .= "$key ";
						
					} else {
						$schedule["weekday"] .= $value . ",";
					}
					break;
					
				case "disk_uuid":
					$settings["disk_uuid"] = $value;
				
	
			}
			$error?$error .= " ":""; // add a space to make room for next errror;
		}
		if($schedule["weekday"]) {
			$schedule["weekday"] = rtrim($schedule["weekday"],","); // remove trailing comma
		} else {
			$schedule["weekday"] = "*";
		}
	}
				
	if(!$error) {
		write_backupsettings($user,$settings);
		if($settings["monthweek"] == "disabled") {
			write_backupschedule($user,$settings["jobname"],"disabled");
		} else {
			write_backupschedule($user,$settings["jobname"],join(" ",$schedule));
		}
	}

	return $error;
}


function delete_backupjob($user,$jobname) {
	$cmd = BACKUP." deletejob $user $jobname";
	exec($cmd,$out,$ret);
	$output = join("\n",$out);
	if(preg_match("/Error/i",$output) ){
		return $output;
	} else {
		return 0;
	}
}

function rename_backupjob($user,$jobname) {
	
}

function run_backupjob($user,$jobname) {

	$cmd = BACKUP." backup $user $jobname";
	print $cmd;
	exec($cmd . " > /dev/null &");
	
}

function create_backupjob($user,$jobname) {

	$return_val["error"] = 0;
	$return_val["status"] = "";
	
	$jobs = get_backupjobs($user);
	foreach ($jobs as $existingjob) {
		if($jobname == $existingjob) {
			$return_val["error"] = 1;
			$return_val["status"] = t("Jobname exists");
			return $return_val;
		}
	}
	
	if(preg_match("/[^\w-]/",$jobname)) {
			$return_val["error"] = 1;
			$return_val["status"] = t("Illegal characters in jobname");
			return $return_val;
	}		
	
	$cmd = BACKUP." createjob $user $jobname";
	exec($cmd,$out,$ret);
	$output = join("\n",$out);
	if(preg_match("/Error/i",$output) ){
		$return_val["error"] = 1;
		$return_val["status"] = $output;
	}
	return $return_val;

}

function read_backupfiles($file) {
	
	if(file_exists($file)) {
		$fh = fopen($file,'r');
		if(filesize($file)) {
			$data = fread($fh,filesize($file));
		}
		fclose($fh);
		if(isset($data)) {
			$data = rtrim($data);
			$a_data = explode("\n",$data);
			return array_map(create_function('$str','return substr($str,2);'),$a_data);
		} else {
			return array();
		}
	} else return array();	
}

function get_backupfiles($user,$jobname) {
	
	$files["include"] = read_backupfiles("/home/".$user."/.backup/".$jobname."/includeglob.list");
	$files["exclude"] = read_backupfiles("/home/".$user."/.backup/".$jobname."/excludeglob.list");
	return $files;		
}

function get_backupschedule($user,$jobname) {
	
	$cmd = BACKUP." printschedule $user $jobname";
	exec($cmd,$jobs,$ret);
	if($jobs) {
		foreach($jobs as $job) {
			preg_match("/^([\w\-]+)\s(.*)/",$job,$matches);
			
			
			if(preg_match("/0 \* \* \* \*/",$matches[2])) {
				// run every hour
				$schedule["monthweek"] = "hourly";
				$schedule["hourly"] = 1;
				
			} elseif (preg_match("/0 \*\/(\d+) \* \* \*/",$matches[2],$time)) {
				$schedule["monthweek"] = "hourly";
				$schedule["hourly"] = $time[1];
	
			} elseif (preg_match("/0 (\d+) \* \* ([\w\,]+)/",$matches[2],$time)) {
				$schedule["monthweek"] = "week";
				$schedule["timeofday"] = $time[1];
				$days = explode(",",$time[2]);
				foreach($days as $day) {
					$schedule["days"][$day] = 1;
				}
	
			} elseif (preg_match("/0 (\d+) (\d+) \* \*/",$matches[2],$time)) {
				$schedule["monthweek"] = "month";
				$schedule["timeofday"] = $time[1];
				$schedule["dayofmonth"] = $time[2];
				
			} else {
				$schedule["monthweek"] = "unknown";
			}
		}
	} else {
			$schedule["monthweek"] = "disabled";
	}
	
	return $schedule;
	
}

function backup_addfile($user,$jobname,$file) {
	
	$cmd = BACKUP." addfiles $user $jobname " . escapeshellarg( $file);
	exec($cmd,$out,$ret);

	// translate here?
	return $out[0];  // return value is json encoded.
	
}

function backup_rmfile($user,$jobname,$file) {
	
	$cmd = BACKUP." removefiles $user $jobname '$file'";
	exec($cmd,$out,$ret);

	// translate here?
	return $out[0];  // return value is json encoded.
	
}

function backup_listdates($user,$jobname) {
	// change this to read a history file with status of each job and time
	$path = "/home/$user/.backup/$jobname/fileinfo/*.info";
	$files = glob($path);
	if($files) {
		$fileinfo = array();
		foreach($files as $file) {
			unset($matches);
			if(preg_match("/(\d{4}-\d{2}-\d{2})-(\d{2}:\d{2}:\d{2})\.([err]*)?.*/",$file,$matches)) {
				$fileinfo[$file]["date"] = $matches[1]; 
				$fileinfo[$file]["time"] = $matches[2];
				if($matches[3]) {
					$fileinfo[$file]["status"] = "highlight";
				} else {	
					$fileinfo[$file]["status"] = "";
				}
			}
		}
		
		krsort($fileinfo);
		return $fileinfo;
	} else {
		return array();
	}
}

function backup_printfilelist($user,$jobname,$file) {

	if(file_exists($file)) {
		$fh = fopen($file,'r');
		if(filesize($file)) {
			$data = fread($fh,filesize($file));
		}
		fclose($fh);
	}
	if(isset($data)) {
		$filelist = array();
		if(preg_match_all("/\s$user\/(?!\.backup).*/",$data,$foo)) {
			// then there is more than ".backup" in the users folder, then show all
			$noshow_userfiles = "";
		} else {
			$noshow_userfiles = "|^$user";
		}
		$pattern = "/\.\$$noshow_userfiles/";  // show ".backup" folder if the folder is included.
		$a_data = explode("\n",$data);
		foreach($a_data as $line) {
			preg_match("/\w+\s(\w+)\s{1,2}(\d+)\s([\d\:]+)\s(\d{4})\s(.*)/",$line,$matches);
			if($matches) {
				$fileinfo = sprintf("%s %s &nbsp;&nbsp; /home/%s",date("Y-m-d",strtotime("$matches[1] $matches[2] $matches[4]")),$matches[3],$matches[5]);
				if( !preg_match($pattern,$matches[5])) { // "/home" is not present, it is added by the above line.
					array_push($filelist,$fileinfo);
				}
			}
		}
		return $filelist;
	} else {
		return array();
	}
}

function backup_restorefile($user,$jobname,$force,$time,$file) {
	
	date_default_timezone_set(get_current_tz());
	if($time) {
		$time = date("c",strtotime($time));
	}
	
	$cmd = BACKUP." restorefiles $user $jobname ".escapeshellarg($force)." $time ".escapeshellarg($file);
	exec($cmd . " > /dev/null &"); 
	
	return 0;
	
}

function backup_current_filelist($user,$jobname) {
		
	$cmd = BACKUP." get_currentfiles $user $jobname";
	exec($cmd,$output); 
	foreach ($output as $line) {
		if(preg_match("/^\{.*\}$/",$line)) {
			// json found
			print $line;
			return $line;
			break;
		}
	}
	return "{'error':0,'status':''}";
	
}


function _lockinfo($lockfile) {
	// read restore lock file to get information
	if(file_exists($lockfile)) {
		$fh_lock = fopen($lockfile,"r");
		$info = fgets($fh_lock);
		fclose($fh_lock);
		$info = rtrim($info);
		if($info) {
			return explode(" ",$info);
		} else {
			return 0;
		}
		
	} else {
			return 0;
	}	
}
function get_restorestatus() {
	
	$lockinfo = _lockinfo(RESTORE_LOCKFILE);
	if($lockinfo) {
		$data["user"] = $lockinfo[0];
		$data["jobname"] = $lockinfo[1];
		
		if(isset($lockinfo[2]) && file_exists($lockinfo[2])) {
			$fh_log = fopen($lockinfo[2],"r");
			$filesize = filesize($lockinfo[2]);
			$data["done"] = 0;
			$data["status"] = t("Retreiving information");
			if($filesize) {
				$log = fread($fh_log,$filesize);
				// split log file
				$log = explode("\n",$log);
				foreach($log as $logline) {
					if (preg_match("/\.\s+Invalid SSH password/",$logline)) {
						$data["done"] = -1;
						$data["status"] = t("Invalid SSH password");
						break;
					} elseif (preg_match("/Errno 20/",$logline)) {
						$data["done"] = -1;
						$data["status"] = t("Error writing to restore target directory.");
						break;
					} elseif (preg_match("/Errno 2/",$logline)) {
						$data["done"] = -1;
						$data["status"] = t("Target directory missing.");
						break;
					} elseif (preg_match("/ERROR 2/",$logline)) {
						$data["done"] = -1;
						$data["status"] = t("Incorrect backup job settings.");
						break;
					}	elseif(preg_match("/ERROR ([\w ]+)/i",$logline,$matches)) {
						if(isset($matches[1])) {
							switch ($matches[1]) {
								case "19" :
									$data["status"] = t("File not found in backupset, nothing restored.");
									break;
								case "11" :
									$data["status"] = t("File exists, select overwrite to force restore.");
									break;
								case "30 BackendException" :
									$data["status"] = t("Could not find backup files. Please check your job settings.");
									break;
								case "30 CollectionsError" :
									$data["status"] = t("No previous backup sets found. Please check connectivity and jobsettings");
									break;
								case "30 AttributeError" :
									$data["status"] = t("Wrong encryption key supplied.");
									break;
								default: 
									$data["status"] = $matches[1];
									break;
							}
						} else {
							$data["status"] = t("Unknown error");
						}
						$data["done"] = -1;
						break;
	
					} else {
						if (preg_match("/\.\s+Processed volume (\d+) of (\d+)/",$logline,$matches)) {
							if(isset($matches[1])) {
								$data["status"] = t("Processed volume") . " $matches[1] " . t("of") . " $matches[2]";
							} else {
								$data["status"] = t("Retreiving volume information");
							}
						}
					}
			}
			fclose($fh_log);
			}			
		} else {
			// lockinfo exists but no log file most likely not created yet.
			$data["done"] = 0;
			$data["status"] = t("Retreiving information");
		}
	} else {
		// no lockinformation -> restore job not running.
		$data["done"] = 1;
		$data["status"] = t("Restore complete");
	}	
	// put together useful info here.
	
	return $data;
	
}

function get_backupstatus() {

	$lockinfo = _lockinfo(BACKUP_LOCKFILE);
	if($lockinfo) {
		$data["user"] = $lockinfo[0];
		$data["jobname"] = $lockinfo[1];
		return $data;
	} else {
		return 0;
	}
}
function backup_readerror($file) {
	if(file_exists($file)) {
		$fh_log = fopen($file,"r");
		$filesize = filesize($file);
		if($filesize) {
			$log = fread($fh_log,$filesize);
		}
		fclose($fh_log);
		$log = preg_replace("/\n/","<br>\n",$log);
		$log = preg_replace("/\./","",$log);
		return $log;
	} else {
		return 0;
	}
}
?>
