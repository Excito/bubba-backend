#!/usr/bin/perl

# File selection is based on matching on the path.
# If the path of a file is matching a criteria that file (or directory and subdirectories) is matched.
# Therefor in order to be able to not always work recursivly three files are needed.
# First include highlevel, then remove from that and finally 


use strict;
use IPC::Open3;
use File::Path qw(rmtree);
use Sys::Syslog qw( :DEFAULT setlogsock);

#use Data::Dumper;


#################################################
#
#   A backup job shall be contained in ARCHIVEINFO_DIR
#   A job consists of three files:
#         jobdescription file: TBD
#         includeglob.list: All files to be included.
#         excludeglob.list: Files to specifically be excluded.
#         both include files are working recursivly.

use constant LOGDIR=>"/var/log/backup/";
use constant ARCHIVEINFO_DIR => ".backup/";
use constant VOL_SIZE => 5;
use constant DUPLICITY => "/usr/bin/duplicity";
use constant NCFTP => "/usr/bin/ncftp";
use constant NCFTPPUT => "/usr/bin/ncftpput";
use constant NCFTPLS => "/usr/bin/ncftpls";
use constant MSGFILE => "/tmp/backup.README";
use constant SSH => "/usr/bin/ssh";
use constant SCRIPTNAME => "/usr/lib/web-admin/backup.pl";
use constant INCLUDEFILE => "includeglob.list";
use constant INCLUDE_CHILD => "include_childglob.list";
use constant EXCLUDEFILE => "excludeglob.list";
use constant JOBFILE => "jobdata";
use constant CHECK_CHILD => 1;
use constant CHECK_PARENT => 0;
use constant CRON_FILE => "/etc/cron.d/bubba-backup";
use constant QUEUE_FILE => "/etc/bubba-backup.queue";
use constant LOCK_FILE => "/var/lock/backup.lock";
use constant LOCK_RESTOREFILE => "/var/lock/restore.lock";
use constant DISKMANAGER => "/usr/sbin/diskmanager";

use constant DEBUG => 0;

sub d_print {
	my $msg = shift;
	if(DEBUG) {
		if($msg) {
			 print "DEBUG: $msg";
		}
	}
}
		

sub return_json {
	use JSON;
	
	my $json_hash = shift;
	my $json = to_json($json_hash);
	print $json;
	print "\n";
	return $json;
}
	
sub exec_cmd {
	use POSIX ":sys_wait_h";

	my $cmd = shift;
	#d_print "CMD: $cmd\n";	
	my @outdata;
	my($in, $out, $err);
	my $pid = open3($in, $out, $err,$cmd);
	d_print "PID: $pid\n";
	while(not waitpid($pid,WNOHANG)) {
    while (<$out>) { 
    	push(@outdata,$_);
    	#print $_;
    }
    sleep 1;
    seek($out, 0, 1);
	}
	return @outdata;
}

sub umount {
	my $mountpath = shift;
	if($mountpath) {
		print("Unmounting disk\n");
		my $cmd = DISKMANAGER . " user_umount $mountpath";
		exec_cmd($cmd);
	}
}

sub test_sshconnection {
	
	use Expect;
	my ($targetdata,$test_targetpath) = @_;
	my $error;
	my $ssh_cmd;
	
	if($test_targetpath) {
		$test_targetpath = $targetdata->{"target_path"};
		$ssh_cmd = "ls -1";
	} else {
		$test_targetpath = "";
		$ssh_cmd = "exit";
	}
	
	d_print "Running ssh to test connection\n";
	my @ssh = (
		"-l" , $targetdata->{"target_user"},
		'-o', "KbdInteractiveAuthentication=yes",
		'-o', "KbdInteractiveDevices=pam",
		'-o', "NumberOfPasswordPrompts=1",
		'-o', "StrictHostKeyChecking=no",
		'-o', "ServerAliveInterval=15",
		'-o', "ServerAliveCountMax=1",
		'-o', "ConnectTimeout=5",
		'-x',
		$targetdata->{"target_host"},
		$ssh_cmd,$test_targetpath
	);
	my $exp = Expect->spawn( SSH, @ssh );
	if($exp) {
		$exp->expect(60,
			[ qr/Pass(word|phrase .*):/i => sub {
					my $exp = shift;
					d_print "Sending password\n";
					$exp->send("$targetdata->{target_FTPpasswd}\n");
					exp_continue; 
				} 
			],
			[ qr/No such file or directory/ => sub {
					$error = "No files found on target\n";
				} 
			],
			[ qr/(Name or service not known)|(Could not resolve hostname|(No route to host))/i => sub {
					$error = "Unable to connect to host\n";
				} 
			],
			[ qr/(timeout, server not responding)|(Connection timed out)/i => sub {
					$error = "Could not connect to server, timeout.\n";
				} 
			],
			[ qr/(authentication failure)|(Permission denied \(publickey,keyboard-interactive\))/i => sub {
					$error = "Invalid user/password combination\n";
				} 
			],
			[ qr/Offending key in/i => sub {
					$error = "Remote identification (RSA fingerprint) has changed.\nBackup job aborted.";
				} 
			],			
		);

		$exp->soft_close();
		if($exp->exitstatus()==1) {
			$error .= "\nssh session exited with non-zero value.\n";
		}
	} else {
		$error = "Could not spawn ssh\n";
	}
	return $error;
}

sub ssh_mkdir {

	use Expect;
	my $targetdata = shift;
	my $error;
	
	print "Running ssh to create dirs\n";
	my $target_path = $targetdata->{"target_path"};
	unless ($target_path) {
		$target_path = ".";
	}
	my @ssh = (
		"-l" , $targetdata->{"target_user"},
		'-o', "KbdInteractiveAuthentication=yes",
		'-o', "KbdInteractiveDevices=pam",
		'-o', "NumberOfPasswordPrompts=1",
		'-o', "StrictHostKeyChecking=no",
		'-o', "ServerAliveInterval=15",
		'-o', "ServerAliveCountMax=1",
		'-o', "ConnectTimeout=5",
		'-x',
		$targetdata->{"target_host"},
		"mkdir","-p","$target_path",
	);
	my $exp = new Expect;
	$exp->raw_pty(1);
	$exp->spawn( SSH, @ssh );
	if($exp) {
		$exp->expect(60,
			[ qr/Pass(word|phrase .*):/i => sub {
					my $exp = shift;
					print "Sending password\n";
					$exp->send("$targetdata->{target_FTPpasswd}\n");
					exp_continue; 
				} 
			],
			[ qr/(Name or service not known)|(Could not resolve hostname|(No route to host))/i => sub {
					$error = "Unable to connect to host\n";
				} 
			],
			[ qr/(timeout, server not responding)|(Connection timed out)/i => sub {
					$error = "Could not connect to server, timeout.\n";
				} 
			],
			[ qr/(authentication failure)|(Permission denied \(publickey,keyboard-interactive\))/i => sub {
					$error = "Invalid user/password combination\n";
				} 
			],
			[ qr/mkdir: cannot create directory.*Permission denied/ => sub {
					$error = "Can not create directory '$targetdata->{target_path}', permission denied\n";
				} 
			],
			[ qr/Offending key in/i => sub {
					$error = "Remote identification (RSA fingerprint) has changed.\nBackup job aborted.";
				} 
			],			
		);

		$exp->soft_close();
		if($exp->exitstatus()==1) {
			$error .= "\nssh session exited with non-zero value.\n";
		}
	} else {
		$error = "Could not spawn ssh\n";
	}
	return $error;
}
	
sub ftp_mkdir {
	
		my $targetdata = shift;
		my $error;
		
		if(open(MSG,">",MSGFILE)) {
			print MSG "Created by Bubba|Two backup script.\nhttp://www.excito.com\n";
			close(MSG);
		}
		
		print "Running ncftpput\n";
		my $cmd = NCFTPPUT . " -t 30 -r 1 -u '".$targetdata->{"target_user"}."' -p '".$targetdata->{"target_FTPpasswd"}."' -m ".$targetdata->{"target_host"}." " .$targetdata->{"target_path"}." ".MSGFILE;
		#print "$cmd";
		my @ncftp_res = exec_cmd($cmd);
		my $res = join(/\n/,@ncftp_res);
		if($res =~ m/Permission denied/) {
			$error = "Error creating backup directory '$targetdata->{target_path}': Permission denied\n";
		}
		if($res =~ m/unknown host/) {
			$error = "Error connecting to target. Target host unknown\n";
		}
		if($res =~ m/password was not accepted/) {
			$error = "Error connecting to target. Invalid user/password combination.\n";
		}
		if($res =~ m/Connection refused/) {
			$error = "Error connecting to target. Connection refused.\n";
		}
		if($res =~ m/Connection timed out/) {
			$error = "Error connecting to target. Connection timed out.\n";
		}
		if($res =~ m/No route to host/) {
			$error = "Error connecting to target. No route to host.\n";
		}

		unlink MSGFILE;
		return $error;

}

sub test_ftpconnection {
	my $targetdata = shift;
	my $error = "";
			
	print "Running ncftpls\n";
	my $cmd = NCFTPLS . " -t 5 -r 1 -u $targetdata->{target_user} -p $targetdata->{target_FTPpasswd} ftp://$targetdata->{target_host}";
	#print "$cmd\n";
	my @ncftp_res = exec_cmd($cmd);
	my $res = join(/\n/,@ncftp_res);
	if($res =~ m/unknown host/) {
		$error = "Error connecting to target. Target host unknown\n";
	}
	if($res =~ m/password was not accepted/) {
		$error = "Error connecting to target. Invalid user/password combination.\n";
	}
	if($res =~ m/Connection refused/) {
		$error = "Error connecting to target. Connection refused.\n";
	}
	if($res =~ m/Connection timed out/) {
		$error = "Error connecting to target. Connection timed out.\n";
	}
	if($res =~ m/No route to host/) {
	$error = "Error connecting to target. No route to host.\n";
	}

	return $error;
	
}

sub esc_chars {
  # will change, for example, a!!a to a\!\!a
  	my $data = shift;
    $data =~ s/([;<>\*\|`&\$!#\(\)\[\]\{\}:'"\ ])/\\$1/g;
    return $data;
}

sub find_disk {

	my $uuid = shift;
	my $cmd = DISKMANAGER . " disk list";
	my @disklist = exec_cmd($cmd);
  my $disks = from_json($disklist[0]);
  my $disk_found = 0;
  my $mountpath = "";
  my %retval;
	$retval{"diskfound"} = 0;
	$retval{"mountpath"} = "";
	$retval{"dev"} = "";
  
  print "Find disk: $uuid\n";
  foreach my $disk (@$disks) {
  	foreach my $partition (@{$disk->{"partitions"}}) {
  		if($partition->{"uuid"} eq $uuid) {
  			print "Disk found,";
  			$retval{"diskfound"} = 1;
  			$retval{"mountpath"} = $partition->{"mountpath"};
  			$retval{"dev"} = $partition->{"dev"};
  		}
  		last;
  	}
	  if($disk_found) {
	  	last;
	  }
	}
	return %retval;
}

sub get_destinations {
	use JSON;
	
	# use this function to return a list of targets
	# each target needs:
	# target_path - path to the backup directory on the remote system.
	#     target_path = /home/admin/backup
	# target_host - hostname or IP of the remote system
	# 		target_host = 192.168.1.5
	# target_user - username to use on the remote system
	# 		target_user = admin
	# target_protocol - protocol to use to connect to the remote system
	# 		target_protocol = scp
	# target_keypath - the path to the identification key to be used with ssh/scp
	#     should be left empty for other protocols
	# target_FTPpasswd - acutal password in plain text for FTP targets
	#     should be left empty for other protocols
	# removed includelist - a path to a list of files to be included in the backup
	# removed excludelist - a path to a list of files to be excluded in the backup
	#			files/directories shall contain full path, beginning with "/"
	# GPG_key - plain text encryption key to use to encrypt data.
	#     should be left empty if no encryption should be used.
	# local_user - which local user is using the backup system.
	# nbr_fullbackups - The number of full backups to keep on the backupserver. "1" means to keep only the last fullbackup.
	#     removal of old full backups will be made _after_ a new has been created.
	# full_expiretime - how long the last full backup is valid. 0 -> never expire
	
	d_print "Setup backupjob.\n";
	
	my($user,$jobname,$nolog) = @_;
	my %targetdata;
	my $jobfile = "/home/" . $user ."/" . ARCHIVEINFO_DIR . $jobname . "/" . JOBFILE;
	my @jobdata;
	my $error = "";
	
	if(open(THISJOB,"<",$jobfile)) {
		@jobdata = <THISJOB>;
		close(THISJOB);
	}

	foreach my $line (@jobdata) {
		chomp($line);
		next if(/^#/);
		$line =~ m/^(\w+)\s+=\s+(.*)$/;
		$targetdata{$1} = esc_chars($2);
		if( !$targetdata{'target_path'} ) {
			#do not allow empty target, set to "."
			$targetdata{'target_path'} = esc_chars(".");
		}
	}
	
	unless($targetdata{"local_user"} && $targetdata{"jobname"}) {
		setlogsock('unix');
    openlog($0,'','user');
    syslog('err', "Unable to retrieve job information for user: $user job: $jobname.");
    closelog;
		print "Error. No backupjob information available, exiting.\n";
		$targetdata{"error"} = "Error. No backupjob information available, exiting.\n";
		return \%targetdata;
	}
	$targetdata{"basedir"} = "/home/" .$targetdata{"local_user"} . "/" . ARCHIVEINFO_DIR . $targetdata{"jobname"} . "/";

	# setup file pointers and check directories.

	# ----  Check existance of include files -----
	my $missing_files = "";
	
	unless(-e $targetdata{"basedir"}.INCLUDEFILE) {
		$missing_files .= " ".INCLUDEFILE;
	}	
	unless(-e $targetdata{"basedir"}.EXCLUDEFILE) {
		$missing_files .= " ".EXCLUDEFILE;
	}	
	unless(-e $targetdata{"basedir"}.INCLUDE_CHILD) {
		$missing_files .= " ".INCLUDE_CHILD;
	}	

	if($missing_files) {
		setlogsock('unix');
    openlog($0,'','user');
    syslog('err', "Missing include files:$missing_files\n");
    closelog;
		print "Error. Missing include files:$missing_files.\nExiting.\n";
		$targetdata{"error"} = "Error. Missing include files:$missing_files.\nExiting.\n";
		return \%targetdata;
	}
		
	
	# ----- Create/check directories ------
	# archive data.
	unless(-e "/home/" .$targetdata{"local_user"} . "/" . ARCHIVEINFO_DIR ) {
		system("mkdir ". "/home/" .$targetdata{"local_user"} . "/" . ARCHIVEINFO_DIR);
	}

	unless(-e $targetdata{"basedir"}) {
		print $targetdata{"basedir"} . " not existing. Creating.\n";
		system("mkdir " . $targetdata{"basedir"});
	}
		
	# log files.
	unless(-e LOGDIR) {
		print LOGDIR . " not existing. Creating.\n";
		system("mkdir " . LOGDIR);
	}
	unless(-e LOGDIR . $targetdata{"local_user"}) {
		system("mkdir ". LOGDIR . $targetdata{"local_user"});
	}

	unless(-e LOGDIR . $targetdata{"local_user"} . "/" . $targetdata{"jobname"}) {
		system("mkdir ". LOGDIR . $targetdata{"local_user"} . "/" . $targetdata{"jobname"});
	}

	my $local_fileinfo = $targetdata{"basedir"} . "fileinfo";
	unless(-e $local_fileinfo) {
		print $local_fileinfo . " not existing. Creating.\n";
		system("mkdir $local_fileinfo");
	}


	if($targetdata{"target_protocol"} eq "file") {

		my %diskinfo = find_disk($targetdata{"disk_uuid"});
    if(!$diskinfo{"diskfound"}) {
    	print("Backup disk not found, exiting\n");
    	$error = "Backup disk not found, exiting\n";

		} else {
			if($diskinfo{"mountpath"}) {
				$targetdata{"target_path"} = $diskinfo{"mountpath"}. "/" . $targetdata{"target_path"};
				print(" and already mounted, using: " . $targetdata{"target_path"} . "\n");
			} else {
				print(" but not mounted\n");
				unless (-e "/mnt/bubba-backup") {
					print("Creating mount path '/mnt/bubba-backup'\n");
					system("mkdir /mnt/bubba-backup");
				}
				unless (-e "/mnt/bubba-backup/".$user) {
					print("Creating mount path '/mnt/bubba-backup/".$user."'\n");
					system("mkdir /mnt/bubba-backup/".$user);
				}
				my $mountpoint = "/mnt/bubba-backup/".$user."/".$jobname;
				unless (-e $mountpoint) {
					print("Creating mount path ".$mountpoint."'\n");
					system("mkdir ".$mountpoint);
				}

				my $cmd = DISKMANAGER . " user_mount ".$diskinfo{"dev"} ." ". $mountpoint;
				exec_cmd($cmd);
				
				# check to see that the disk is mounted.
				my %verified_mountpath = find_disk($targetdata{"disk_uuid"});
				if($verified_mountpath{"mountpath"}) {
					print(" and verified disk mounted on ".$verified_mountpath{"mountpath"}."\n");
			    $targetdata{"target_path"} = $verified_mountpath{"mountpath"}."/".$targetdata{"target_path"};
			    $targetdata{"mountpath"} = $verified_mountpath{"mountpath"};
				} else {
					print(" but unable to verify mountpoint, exiting.\n");
					$error = "Disk found, but unable to verify mountpoint, exiting.\n";
				}
			}
		}
	} else {
		$targetdata{"target_path"} =~ s/^\/*//;
	}

	if($error) {
		unless($nolog) {
			my $infofile = $local_fileinfo . "/" . now() . ".err.info";
			print("Writing error log to " . $infofile . "\n");
			
			open(my $fh_FILEINFO, '>',$infofile );
			chmod(0600, $fh_FILEINFO);
			print $fh_FILEINFO $error;
		  close($fh_FILEINFO);
		}
		$targetdata{"error"} = $error;
	}
	return \%targetdata;
	
}

sub now {
	
		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
		my $date = sprintf("%04s-%02s-%02s",$year+1900,$mon+1,$mday);
		my $time = sprintf("%02s:%02s:%02s",$hour,$min,$sec);
	  return "$date-$time";
}

sub setup_jobinfo {
	
	my $targetdata = shift;

	my $cmd;
	my $key;
	my $no_crypt;
	my $ssh_key;
	my $ssh_key;
	my $use_sshpasswd;
	my $full_expiretime;

	# --- Get job data ------
	if($targetdata->{"GPG_key"}) {
		$key = "PASSPHRASE=\"" . $targetdata->{"GPG_key"} . "\" ";
	} else {
		$no_crypt = "--no-encryption";
	}
	
	if(($targetdata->{"target_protocol"} eq "scp") or ($targetdata->{"target_protocol"} eq "FTP")) {
		if($targetdata->{"target_keypath"}) {
			$ssh_key = "--ssh-options=\"-oIdentityFile=" . $targetdata->{"target_keypath"} . "\" ";
		} else {
			$key .= "FTP_PASSWORD=\"" . $targetdata->{"target_FTPpasswd"} . "\" ";
			if($targetdata->{"target_protocol"} eq "scp") {
				$use_sshpasswd = " --ssh-askpass --ssh-options=\"-oStrictHostKeyChecking='no' -oConnectTimeout='5'\"";
			}
		}
	}
	
	my $target = $targetdata->{"target_protocol"} . "://";

	if(($targetdata->{"target_protocol"} ne "file")) {
		if ($targetdata->{"target_user"}) {
			$target .= $targetdata->{"target_user"} ."\@" ;
		}
		if($targetdata->{"target_host"}) {
			$target .= $targetdata->{"target_host"};
		}
		if($targetdata->{"target_path"}) {
			$target	 .= "/" . $targetdata->{"target_path"} . "/" . $targetdata->{"jobname"};
		} else {
			$target	 .= "/" . $targetdata->{"jobname"};
		}
	
	} else {
		$target	 .= $targetdata->{"target_path"} . "/" . $targetdata->{"jobname"};
	}
	
	if($targetdata->{"full_expiretime"}) {
		$full_expiretime = " --full-if-older-than "  . $targetdata->{"full_expiretime"};
	}

	return ($cmd,$key,$no_crypt,$ssh_key,$ssh_key,$use_sshpasswd,$full_expiretime,$target);

}


sub run_backup {
	use Fcntl ':flock'; # import LOCK_* constants

	my $user = $ARGV[1];
	my $jobname = $ARGV[2];
	my $newjobs = 1;
	
	#queue job here.
	open(my $fh_QUEUE,">>",QUEUE_FILE) or die "Unable to open queue file\n";
	print("Queueing job: $jobname for user: $user\n");
	print $fh_QUEUE "$user $jobname\n";
	close($fh_QUEUE);
		
	if (-e LOCK_FILE) {
		open(my $fh_LOCK,"<",LOCK_FILE);
		flock($fh_LOCK,LOCK_EX | LOCK_NB) or die "Unable to get lock\n";
		# no lock, continue.
	}
		
	open(my $fh_LOCK,">",LOCK_FILE);
	flock($fh_LOCK,LOCK_EX | LOCK_NB) or die "Unable to get lock\n";
		#lock granted, no other instance is running
		
		# run all jobs in the queue
		# just read the first entry, then close the file
		while($newjobs) {
			$newjobs = 0;
			open(my $fh_QUEUE,"<",QUEUE_FILE) or die "Unable to open queue file\n";
			my @queue = <$fh_QUEUE>;
			close($fh_QUEUE);
			foreach my $jobline (@queue) {
				if($jobline =~ m/^(\w+)\s+([\w\-]+)$/) {
					print("New job found for $1 $2\n");
					$newjobs = 1;
					$user = $1;
					$jobname = $2;
					last;
				}
			}
			
			if($newjobs) {
				# remove the job from the list then write it to file.
				shift(@queue);
				open(my $fh_QUEUE,">",QUEUE_FILE);
				if($fh_QUEUE) {
					print $fh_QUEUE @queue;
					close($fh_QUEUE);
		
					print("Running queued job: $jobname for user: $user \n");
					print $fh_LOCK "$user $jobname";
					if(run_now($user,$jobname)) {
						print $_;
					}
				} else {
					print("Unable to open queue file\n");
				}
			}			
		}			
		flock($fh_LOCK,LOCK_UN);
		close($fh_LOCK);
		unlink(LOCK_FILE)
}

sub removelogs {

	my ($logdir,$logfile) = @_;	

	print("Getting date from $logfile\n");
	my %month2nbr = ("Jan","01","Feb","02","Mar","03","Apr","04","May","05","Jun","06","Jul","07","Aug","08","Sep","09","Oct","10","Nov","11","Dec","12");
	# -- Try to find any removed backupsets.
	open(my $fh_remove,"<",$logfile);
	my $deletefiles = 0;
	#my %deletedate;
	my $oldestdate;
	foreach my $line (<$fh_remove>) {
		if($deletefiles) {
			if($line =~ m/\. \w{3} (\w{3}) (\d{2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})/) {
				$oldestdate = $6.$month2nbr{$1}.$2.$3.$4.$5;
			} else {
				last;
			}
		}
		if($line =~ m/Deleting backup set/) {
			$deletefiles = 1;
		}
			
	}
	close($fh_remove);

	my @logfiles = glob($logdir."/*");
	print(" ------  Removing logfiles -----\n");
	foreach my $file (@logfiles) {
		$file =~ m/(\d{4})-(\d{2})-(\d{2})-(\d{2}):(\d{2}):(\d{2})\.\w+/;
		my $filetime = $1.$2.$3.$4.$5.$6;
		if($filetime < $oldestdate) {
			print("Delete $file\n");
			unlink($file);
		}			
			
	}
}

sub run_now {

	use File::Glob;

	my ($user,$jobname) = @_;
	print("RUN NOW: $user $jobname \n");

	my $targetdata = get_destinations($user,$jobname);
	if($targetdata->{"error"}) {
		return $targetdata->{"error"};
	}
	
	my ($cmd,$key,$no_crypt,$ssh_key,$ssh_key,$use_sshpasswd,$full_expiretime,$target) = setup_jobinfo($targetdata);
	my $now = now();
	
	my $includelist = $targetdata->{"basedir"} .INCLUDEFILE;
	my $include_childlist = $targetdata->{"basedir"} .INCLUDE_CHILD;
	my $excludelist = $targetdata->{"basedir"} .EXCLUDEFILE;
		
	my $local_archiveinfo = $targetdata->{"basedir"} . "archives";
	my $logdir = LOGDIR . $targetdata->{"local_user"} . "/" . $targetdata->{"jobname"};
	my $error = "";
	my $warn_msg = "";

	unless(-e $local_archiveinfo) {
		print $local_archiveinfo . " not existing. Creating.\n";
		system("mkdir $local_archiveinfo");
	}

	my $local_fileinfo = $targetdata->{"basedir"} . "fileinfo";

	my $logfile = $logdir . "/". $now.".log";
	print("Logging to $logfile\n");

	if($targetdata->{"target_protocol"} eq "scp") {
		# Always run this function since error messages are better here.
		$error = ssh_mkdir($targetdata);
	}
	if($targetdata->{"target_protocol"} eq "FTP") {
		$error = ftp_mkdir($targetdata);
	}

	if($targetdata->{"GPG_key"}) {
		# backup will fail if the public keyring is not present.
		unless(-e "/root/.gnupg") {
			print "Generating public keyring\n";
			system("/usr/bin/gpg --list-keys");
		}
	}
	unless($error) {
		print "Starting backup\n";
		# ---------- Setup backup command ------------
		$cmd = $key . "nice " . DUPLICITY . " --time-separator '.' -v 5 $full_expiretime $use_sshpasswd $no_crypt  --num-retries 2 --volsize " . VOL_SIZE . " --log-file $logfile --archive-dir $local_archiveinfo $ssh_key --exclude-globbing-file " . $excludelist . " --include-globbing-file " . $includelist . " --include " . $local_fileinfo  . " --include '$targetdata->{basedir}*glob.list' --include '$targetdata->{basedir}jobdata' --exclude \"**\"  /home " . $target;
	
		#print "$cmd\n";
		my @outdata = exec_cmd($cmd);
	
		print("Backup done.\n");
		my $print_stats;
		
		# ------ Change file permissions if the target is "file" ------
		if($target =~ m/^file:\/\/(.*)/) {
			print "File target, setting permissions\n";
			print "Target is: $1 \n";
			print exec_cmd("chown -R admin $1");		
		}
		
		
			
		open(LOGFILE,'>>',$logfile);
	
		foreach my $line (@outdata) {
	#	foreach my $line (<$out>) {
			if ( $line =~ m/Backup Statistics/ ) {
				$print_stats = 1;
			}
			if ($print_stats) {
				print $line;
				print LOGFILE $line;
			}
		}
		close(LOGFILE);
		
	
		# ----- Investigate logfile ---------
		open(LOGFILE,'<',$logfile);
		my $warnings = 0;
		foreach my $line (<LOGFILE>) {
			if ($warnings) {
				#grab warning message
				SWITCH: {
					if($line =~ m/Remote file or directory '(\w+)\/\w+' does not exist/) {
						$warn_msg .= "Remote directory '$1' does not exist";
						last SWITCH;
					}
					if($line =~ m/Invalid SSH password/) {
						$warn_msg .= "Invalid SSH password";
						last SWITCH;
					}
					if($line =~ m/sftp.*attempts?\s?(#\d+)?/) {
						print "Matched sftp warning\n";
						if($1) {
							$warn_msg .= " attempt $1\n";
						}
						last SWITCH;
					}
					# else	
					$warn_msg .= $line;
				}
				$warnings = 0;
			}
			
			if ($line =~ m/(^WARNING[^S])/i ) {
				$warnings = 1;
			}

			if($error) {
				#grab error message
				if($line =~ m/^\. (.*fail.*)|(.*invalid.*)|(.*no space.*)/i) {
					#$line = <LOGFILE>;
					#$line =~ /\.\s(.*)/;
					#$error .= $1;
					$error .= $line;
				}
				if($line =~ m/^\. OSError\: \[Errno 2\] No such file or directory\: /i) {
					$error .= "Unable to create files on target.\n";
				}
				$error .= $warn_msg;
				$warn_msg = "";
			}

			if ( $line =~ m/(^ERROR[^S])/i ) {
				unless($error) {
					$error = "Errors/warnings encountered during backup.\n";
					print("Errors/warnings encountered during backup.\n");
					print("ERROR found on line: $line \n");
				}
			}
		}		
		close(LOGFILE);
	}
	

	# --- Write file information to file
	my $infofile;
	$now = now();

	if($error) {
		$infofile = $local_fileinfo . "/" . $now . ".err.info";
		open(my $fh_FILEINFO, '>',$infofile );
		chmod(0600, $fh_FILEINFO);
		print $fh_FILEINFO $error;
		print "Errors found:\n";
		print "$error\n";
	  if($warn_msg) {
			print $fh_FILEINFO $warn_msg;
		}
		close($fh_FILEINFO);
		
	} else {

		# ---  Get what files are included in the backup.
		$cmd = $key . DUPLICITY . " list-current-files --time-separator '.' $use_sshpasswd $no_crypt --num-retries 2 $ssh_key " . $target;
		#print $cmd;
		#print "\n";
	

		my @output = exec_cmd($cmd);

		#find GPG error in output
		my $info_error = "";
		foreach my $line (@output) {
			if($line =~ m/errors?\s/i) {
				# part of filename?
				if($line =~ m/	^\w{3}\s\w{3}\s{1,2}                       # day + month 'Mon Jun '
									\d{1,2}\s											# date '03'
									\d{2}:\d{2}:\d{2}\s								# time 01:02:03
									\d{4}\s												# year '2010'
								/ix) {
				} else {
					unless($info_error) {
						$info_error .= "Error found, ".$line."\n";
					}
					if($line =~ m/GnuPG exited non-zero, with code 2/) {
						$info_error .= "Encryption key error";
					}
				}
			}
		}
		if($info_error) {
			$infofile = $local_fileinfo . "/" . $now . ".err.info";
		} else {
			$infofile = $local_fileinfo . "/" . $now . ".info";
		}
		open(my $fh_FILEINFO, '>',$infofile );
		chmod(0600, $fh_FILEINFO);
		print $fh_FILEINFO "# Fileinformation from $now\n";
	
		print "List file info to $infofile\n";
		if($info_error) {
			print $fh_FILEINFO $info_error;
		} else {
			print $fh_FILEINFO @output;
		}
		
		close($fh_FILEINFO);


		# -------  Cleanup only if backup was successful ----------

		if($targetdata->{"nbr_fullbackups"}>0) {
			my $logfile = $logdir . "/". $now.".removefull";
			print("Logging removal of fullbackups to: $logfile \n");
	
			$cmd = $key . DUPLICITY . " remove-all-but-n-full " . $targetdata->{"nbr_fullbackups"} . " --num-retries 2 --force $use_sshpasswd -v 5 $no_crypt --log-file $logfile $ssh_key $target";
		  exec_cmd($cmd);
		  #print "$cmd\n";

			removelogs($local_fileinfo,$logfile);
			removelogs($logdir,$logfile);

			my $logfile = $logdir . "/". $now.".cleanup";
			print("Logging removal of cleanup log to: $logfile \n");
			$cmd = $key . DUPLICITY . " cleanup --num-retries 2 --force $use_sshpasswd -v 5 $no_crypt --log-file $logfile $ssh_key $target";
		  #print "$cmd\n";
			exec_cmd($cmd);

		}
	}
	print("Info to: $infofile \n");
	# ---  umount disk if it was mounted by backup script.
	umount($targetdata->{"mountpath"});
	
#  foreach my $file (<$out>) {
#  	# example entry: Mon Feb 16 15:02:10 2009 home/storage
#  	$file =~ m/^\w+\s+\w+\s+\d+\s+\d+:\d+:\d+\s+\d+\s(.*)/;
#  	my $fout;
#  	my $filename = esc_chars($1);
#		my $pid = open3($in, $fout, $err,"ls -dl /".$filename);
#		waitpid($pid,0);
#		my @output = <$fout>;
#  	print $fh_FILEINFO @output;
#  }	
  
  # ---  Remove old full-backups ----
}	

sub get_lastsetinfo {

	use Fcntl ':flock'; # import LOCK_* constants

	my %retval;
	$retval{"error"} = 1;
	$retval{"status"} = "Unknown error";

	my $user = $ARGV[1];
	my $jobname = $ARGV[2];
	my $error;
	my $fh_LOCK;
	
	if(-e LOCK_RESTOREFILE) { # does the file exist?
		open($fh_LOCK,"<",LOCK_RESTOREFILE);
		unless(flock($fh_LOCK,LOCK_EX | LOCK_NB)) {
			d_print "Unable to get lock\n";
			$retval{"error"} = 1;
			$retval{"status"} = "Restore locked by another process";
			return_json(\%retval);
			return 0;
		}
		#open for write
		open($fh_LOCK,">",LOCK_RESTOREFILE);

	} else {
		#open for write
		open($fh_LOCK,">",LOCK_RESTOREFILE);
		flock($fh_LOCK,LOCK_EX | LOCK_NB);
	}
	print("Restoring files for $ARGV[1] job $ARGV[2].\n");

	my $targetdata = get_destinations($user,$jobname,1);
	
	if($targetdata->{"target_protocol"} eq "scp") {
		$error = test_sshconnection($targetdata,1);
		if($error) {
			$retval{"status"} = $error;
			return_json(\%retval);
			flock($fh_LOCK,LOCK_UN);
			close($fh_LOCK);
			unlink(LOCK_RESTOREFILE);
			return 0;
		}
	}

	if($targetdata->{"target_protocol"} eq "FTP") {
		$error = test_ftpconnection($targetdata,1);
		if($error) {
			$retval{"status"} = $error;
			return_json(\%retval);
			flock($fh_LOCK,LOCK_UN);
			close($fh_LOCK);
			unlink(LOCK_RESTOREFILE);
			return 0;
		}
	}
	
	my ($cmd,$key,$no_crypt,$ssh_key,$ssh_key,$use_sshpasswd,$full_expiretime,$target) = setup_jobinfo($targetdata);

	# ---- Get the status of the backupsets
	$cmd = $key . DUPLICITY . " collection-status --time-separator '.' $use_sshpasswd $no_crypt --num-retries 2 $ssh_key " . $target;
	d_print "$cmd\n";
	my @output = exec_cmd($cmd);
	d_print @output;
	my %month2nbr = ("Jan","01","Feb","02","Mar","03","Apr","04","May","05","Jun","06","Jul","07","Aug","08","Sep","09","Oct","10","Nov","11","Dec","12");
	my $now = ""; 
	foreach my $line (@output) {
		# find newest date, listed last.
		if($line =~ m/(\w+)\s+(\d{1,2})\s+(\d{2}:\d{2}:\d{2})\s+(\d{4})/) {
			$now = $4."-".$month2nbr{$1}."-".$2."-".$3;
		}
		if($line =~ m/(No backup chains with active signatures found)|(No such file or directory)/) {
			$retval{"status"} = "No files found on target\n";
			return_json(\%retval);
			flock($fh_LOCK,LOCK_UN);
			close($fh_LOCK);
			unlink(LOCK_RESTOREFILE);
			umount($targetdata->{"mountpath"});  # unmount disk (umount checks if it was mounted by script)
			return 0;
		}
	}	
	
	d_print @output;

	# ---  Get what files are included in the backup.
	$cmd = $key . DUPLICITY . " list-current-files --time-separator '.' $use_sshpasswd $no_crypt --num-retries 2 $ssh_key " . $target;
	d_print "$cmd\n";
	@output = exec_cmd($cmd);
	#find GPG error in output
	my $info_error = "";
	my $i=0;
	foreach my $line (@output) {
		$i++;
		if($line =~ m/error/i) {
			unless($info_error) {
				$info_error .= "Error found. ";
			}
			if($line =~ m/GnuPG exited non-zero, with code 2/) {
				$info_error .= "Encryption key error";
			}
		}
	}

	my $infofile;
	my $local_fileinfo = $targetdata->{"basedir"} . "fileinfo";

	if($info_error) {
		$infofile = $local_fileinfo . "/" . $now . ".err.info";
	} else {
		$infofile = $local_fileinfo . "/" . $now . ".info";
	}
	open(my $fh_FILEINFO, '>',$infofile );
	chmod(0600, $fh_FILEINFO);
	print $fh_FILEINFO "# Fileinformation from $now\n";

	print "List file info to $infofile\n";
	if($info_error) {
		print $fh_FILEINFO $info_error;
	} else {
		print $fh_FILEINFO @output;
	}
	
	close($fh_FILEINFO);

	umount($targetdata->{"mountpath"});  # unmount disk (umount checks if it was mounted by script)
	flock($fh_LOCK,LOCK_UN);
	close($fh_LOCK);
	unlink(LOCK_RESTOREFILE);

	$retval{"error"} = 0;
	$retval{"status"} = "OK";
	return_json(\%retval);

}

sub write_filelists {
	
	my ($user,$jobname) = @_;
	my $basedir = "/home/" . $user . "/" . ARCHIVEINFO_DIR . $jobname . "/";

	our @includeglob;
	our @include_childglob;
	our @excludeglob;
	
	my $includelist = $basedir . INCLUDEFILE;
	my $include_childlist = $basedir .INCLUDE_CHILD;
	my $excludelist = $basedir .EXCLUDEFILE;

	@includeglob = sort(@includeglob);
	@include_childglob = sort(@include_childglob);
	@excludeglob = sort(@excludeglob);

	open(my $fh_INCLUDE,">",$includelist) or die "Unable to open includelist ($includelist) for writing";
	chmod(0600, $fh_INCLUDE);
	print $fh_INCLUDE @includeglob;
	close($fh_INCLUDE);

	open(my $fh_INCLUDECHILD,">",$include_childlist) or die "Unable to read includelist ($include_childlist)";
	chmod(0600, $fh_INCLUDECHILD);
	print $fh_INCLUDECHILD @include_childglob;
	close($fh_INCLUDECHILD);

	open(my $fh_EXCLUDE,">",$excludelist) or die "Unable to open excludelist ($excludelist) for writing";
	chmod(0600, $fh_EXCLUDE);
	print $fh_EXCLUDE @excludeglob;
	close($fh_EXCLUDE);
	
}

sub read_filelists {
	
	my ($user,$jobname) = @_;
	my $basedir = "/home/" . $user . "/" . ARCHIVEINFO_DIR . $jobname . "/";

	our @includeglob;
	our @include_childglob;
	our @excludeglob;
	
	my $includelist = $basedir .INCLUDEFILE;
	my $include_childlist = $basedir .INCLUDE_CHILD;
	my $excludelist = $basedir .EXCLUDEFILE;
	
	
	if(open(INCLUDE,"<",$includelist)) {
		@includeglob = <INCLUDE>;
		close(INCLUDE);
	}
	
	if(open(INCLUDECHILD,"<",$include_childlist)) {
		@include_childglob = <INCLUDECHILD>;
		close(INCLUDECHILD);
	}
	
	if(open(EXCLUDE,"<",$excludelist)) {
		@excludeglob = <EXCLUDE>;
		close(EXCLUDE);
	}	
}

sub checkfile_included {
	my ($file,$child) = @_;
	d_print("Checkfile included\n");
	#print "FILE: $file, Check child: $child\n";
	my $index = 1;
	our @includeglob;
	our @include_childglob;

	my @file_to_check;
	if($child) {
		@file_to_check = @include_childglob;
		#print "Checking child file\n";
		$child = "child";
	} else {
		@file_to_check = @includeglob;
		#print "Checking main include file\n";
		$child = "";
	}
	
	foreach my $filename (@file_to_check) {
		my $name = $filename;
		$file =~ s/(.*?)\/?$/$1/; # remove any trailing "/"
		$name =~ s/^[\+-]\s+(.*?)\/?$/$1/; #remove +/- in the beginning of the line and any trailing "/"
		d_print("INC: FILE: $file <-> LIST: $name\n");
		chomp($name);
		$name =quotemeta($name);
		if($file =~ m/$name/) {
			#print "$file is in included $child list\n";
			if($file =~ m/^$name$/) {
				d_print("Exact match\n");
				return -$index;
			} else {
				return $index;
			}
		}
		$index++;
	}
	return 0;
}

sub checkfile_excluded {
	d_print("Checking excluded file list\n");
	my $file=shift;
	my $index = 1;
	our @excludeglob;
	
	foreach my $filename (@excludeglob) {
		my $name = $filename;
		$file =~ s/(.*?)\/?$/$1/; # remove any trailing "/"
		$name =~ s/^[\+-]\s+(.*?)\/?$/$1/; #remove +/- in the beginning of the line and any trailing "/"
		chomp($name);
		$name =quotemeta($name);
		d_print("File: $file <-> List: $name\n");
		if($file =~ m/$name/) {
			d_print("$file is in excluded list ($name)\n");
			if($file =~ m/^$name$/) {
				d_print("Exact match\n");
				return -$index;
			} else {
				return $index;
			}
		}
		$index++;
	}
	return 0;
}

sub remove_rec {

	my ($file,$listref) = @_;
	my $i=0;
	my @indexes_to_remove;
	
	d_print("Removing recursivly from $file \n");
	
	$file = quotemeta($file);
	foreach my $name (@$listref) {
		d_print("REC: FILE: $file <-> LIST: $name");
		if($name =~ m/$file/) {
			push(@indexes_to_remove,$i);
		}
		$i++
	}
	foreach my $index (@indexes_to_remove) {
		d_print("Removing index $index (" . chomp($listref->[$index]) .")\n");
		delete $listref->[$index];
	}	
}

sub rm_files {
	use JSON;
	
	my $user = $ARGV[1];
	my $jobname = $ARGV[2];
	my @filelist = split(/;/,$ARGV[3]);
	my %retval;
	
	our @includeglob;
	our @excludeglob;
	
	$retval{"error"} = 1;
	read_filelists($user,$jobname);
	
	foreach my $file (@filelist) {
		$file =~ s/^\///; # remove any leading "/"
		unless($file =~ m/^home/) {
			$file = "/home/" . $file;
		} else {
			$file = "/" . $file;
		}

		if($file =~ m/\.\./) {
			$retval{"error"} = 1;
			$retval{"status"} = "not allowed.";
			$retval{"file"} = $file;
			last;
		}
		my $included = checkfile_included($file,0); # do not check childglob.
		if($included < 0) { # exakt match, remove the file from the include list
			d_print("Removed $file from includelist.\n");
			remove_rec($file,\@includeglob);
			$retval{"error"} = 0;
			$retval{"status"} = "Removed from backup.";
			$retval{"file"} = $file;
		} else {
			# file is recursivly included, should it be added to excludelist?
			if(checkfile_excluded($file)) {
				d_print("$file already excluded.\n");
				$retval{"error"} = 1;
				$retval{"status"} = "Already excluded (recursivly).";
				$retval{"file"} = $file;
			} else {
				#add file to exclude list
				$retval{"error"} = 0;
				$retval{"status"} = "Added to excludelist.";
				$retval{"file"} = $file;
				d_print("Excluding $file.\n");
				push(@excludeglob, "- $file\n");
			}
		}
	}
	unless($retval{"error"}) {
		write_filelists($user,$jobname);
	}

	my $json = to_json(\%retval);
	print $json;
	print("\n");
	return $json;
	
}

sub add_files {
	use JSON;
	
	my $user = $ARGV[1];
	my $jobname = $ARGV[2];
	my @filelist = split(/\t/,$ARGV[3]);
	my %retval;
	
	our @includeglob;
	our @excludeglob;
	
	$retval{"error"} = 1;
	read_filelists($user,$jobname);
	
	foreach my $file (@filelist) {
		$file =~ s/^\///; # remove any leading "/"
		unless($file =~ m/^home/) {
			$file = "/home/" . $file;
		} else {
			$file = "/" . $file;
		}

		if($file =~ m/\.\./) {
			$retval{"error"} = 1;
			$retval{"status"} = "not allowed.";
			$retval{"file"} = $file;
			last;
		}
			
		if(checkfile_excluded($file)<0) {
			#remove the file from the exclude list
			d_print("Removed $file from excludelist.\n");
			remove_rec($file,\@excludeglob);
			$retval{"error"} = 0;
			$retval{"status"} = "Removed from excludelist.";
			$retval{"file"} = $file;
		} else {
			# file is not excluded, should it be added?
			if(checkfile_included($file,0)) { # do not check childglob.
				d_print("$file already included.\n");
				$retval{"error"} = 1;
				$retval{"status"} = "Already included (recursivly).";
				$retval{"file"} = $file;
			} else {
				#add File
				$retval{"error"} = 0;
				$retval{"status"} = "Added to backup.";
				$retval{"file"} = $file;
				d_print("Adding $file.\n");
				push(@includeglob, "+ $file\n");
			}
		}
	}
	unless($retval{"error"}) {
		write_filelists($user,$jobname);
	}

	my $json = to_json(\%retval);
	print $json;
	print "\n";
	return $json;
	
}

sub restore_files {
	use Fcntl ':flock'; # import LOCK_* constants

	my %retval;
	my $fh_LOCK;
	
	
	if(-e LOCK_RESTOREFILE) { # does the file exist?
		open($fh_LOCK,"<",LOCK_RESTOREFILE);
		unless(flock($fh_LOCK,LOCK_EX | LOCK_NB)) {
			d_print "Unable to get lock\n";
			$retval{"error"} = 1;
			$retval{"status"} = "Restore locked by another process";
			return_json(\%retval);
			return 0;
		}
		#open for write
		open($fh_LOCK,">",LOCK_RESTOREFILE);

	} else {
		#open for write
		open($fh_LOCK,">",LOCK_RESTOREFILE);
		flock($fh_LOCK,LOCK_EX | LOCK_NB);
	}
	
	print("Restoring files for $ARGV[1] job $ARGV[2].\n");
	my $user = $ARGV[1];
	my $jobname = $ARGV[2];
	my $force = $ARGV[3];

	print $fh_LOCK "$user $jobname ";
	my $targetdata = get_destinations($user,$jobname,1);
	die "Incorrect jobsettings\n" if $targetdata->{"error"}; 
	

	
	# do we need to make a heavier sanity check here?
	my $restoredate = $ARGV[4];
	my $file_to_restore = $ARGV[5];
	$file_to_restore =~ s/^\///; # remove leading "/"
	
	my $logdir = LOGDIR . $targetdata->{"local_user"} . "/" . $targetdata->{"jobname"};
	unless(-e $logdir) {
		print $logdir . " not existing. Creating.\n";
		system("mkdir $logdir");
	}

	my $logfile = $logdir . "/". now() .".restore";
	print("Logging to $logfile\n");
	print $fh_LOCK "$logfile";

	my ($cmd,$key,$no_crypt,$ssh_key,$ssh_key,$use_sshpasswd,$full_expiretime,$target) = setup_jobinfo($targetdata);
	

	if($restoredate) {
		$restoredate = "--restore-time $restoredate";
	} else {
		$restoredate = "";
	}

	my $file_target = "/".$file_to_restore; # make sure that there is a leading "/"
	$file_to_restore =~ s/^\/?home\///; # remove "/home/"
	my $set_permissions;
	my $target_dir;
	
	if($force eq "overwrite") {
		# overwrite to the same location
		$force = "--force";
		d_print("Overwrite: " . $file_target);
	} elsif($force ne "0") {
		# write backup to target specified by the "force" paramter
		$set_permissions = "/home/$user/$force";
		$file_to_restore =~ m/(^[^\/]*)/;
		$target_dir = "/home/$user/$force/$1";
		d_print("TARGET_DIR: $target_dir \n");
		unless(-e $target_dir) {
			d_print $target_dir . " not existing. Creating.\n";
			system("mkdir","-p",$target_dir);
		}

		# first directory level is already in $target_dir
		if($file_to_restore =~ m/.+\/(.*)?$/) {
			$file_target = "$target_dir/$1";
		} else {
			$file_target = "$target_dir/";
		}
		$force  = "";
 	} else {
 		#restore any missing files to original location.
		$force  = "";
	}
	
	$file_to_restore = esc_chars($file_to_restore);
	$file_target = esc_chars($file_target);
	$target = esc_chars($target);
	
	$cmd = $key . DUPLICITY . " -v 5 $restoredate $use_sshpasswd $no_crypt $force --num-retries 2 --log-file $logfile --file-to-restore $file_to_restore $ssh_key $target $file_target";
	d_print("$cmd\n");
 	exec_cmd($cmd);
 	
 	if($set_permissions) {
	 	d_print "Changing permissions on: $set_permissions\n";
		system("chown -R $user:users $set_permissions");
	}
	
	# ---  umount disk if it was mounted by backup script.
	umount($targetdata->{"mountpath"});

	sleep 5; # allow any running php-instance to read the last bit of the log file.
	flock($fh_LOCK,LOCK_UN);
	close($fh_LOCK);
	unlink(LOCK_RESTOREFILE);

}

sub list_jobs {
	my $user = $ARGV[1];
	my $backupdir = $user . "/" . ARCHIVEINFO_DIR . "*";
	
	my @files = </home/$backupdir>;
	foreach my $file (@files) {
		if(-d $file) {
			$file =~ m/.*\/(.+)$/o;
 	 		print $1 . "\n";
 		}
	}
} 

sub print_schedule {
	
	my @cronfile;
	my $user = $ARGV[1];
	my $jobname = $ARGV[2];
	
	
	if(open(CRON,"<",CRON_FILE)) {
		@cronfile = <CRON>;
		close(CRON);
	}

	foreach my $line (@cronfile) {
		# minute, hour, day of month, Month, day of week, (user name), command 
		#my $matchpattern ="([\d\/\*]+)\s([\d\/\*]+)\s([\d\/\*]+)\s([\d\/\*]+)\s([\d\/\*]+)\s+[\w\/]+backup\.pl\s+".$user."\s+".$jobname;

		if($line =~ m/^								# line start 
								([\w\/\*]+)\s+	# match minute
								([\w\/\*]+)\s+	# match hour
								([\w\/\*]+)\s+	# match day of month
								([\w\/\*]+)\s+	# match Month
								([\w\/\*\,]+)\s+	# match day of week
								root\s+				# backup is run by root
								\/usr\/lib\/web\-admin\/backup\.pl\s+		# match the script_name
								backup\s+			# match the backup command
								$user\s+			# match the user
								$jobname			# match the jobname
		/x) {								
			print("$jobname $1 $2 $3 $4 $5\n");
		}
	}
	
}

sub write_schedule {
	
	my @cronfile;
	my $user = $ARGV[1];
	my $jobname = $ARGV[2];
	my $schedule = $ARGV[3];
	my $nbrelements;
	my $jobfound = 0;
	
	if($schedule ne "disabled") {
		my @test = split(/ /,$schedule);
		$nbrelements = @test;
	}

	if($nbrelements != 5 && $schedule ne "disabled") {
		print("Error, schedule is incorrect\n");
	} else {
		if(open(CRON,"<",CRON_FILE)) {
			@cronfile = <CRON>;
			close(CRON);
		}
		my $new_line = "$schedule root " . SCRIPTNAME . " backup $user $jobname\n";
		foreach my $line (@cronfile) {
			if( $line =~ m/$user\s+$jobname/ ) { 
				# correct user and jobname
				$jobfound = 1;
				if($schedule eq "disabled") {
					$line="";
				} else {
					$line = $new_line;
				}
			}
		}
		if(!$jobfound && $schedule ne "disabled") {
			# new job, add it to CRON
			push(@cronfile, $new_line);
		}
		
		if(open(CRON,">",CRON_FILE)) {
			print CRON  @cronfile;
			close(CRON);
			print("Cronfile written.\n");
		} else {
			print("Error opening cronfile");
		}
	}	

}

sub create_job {

	my $user = $ARGV[1];
	my $jobname = $ARGV[2];

	my $userdir = "/home/" . $user . "/" . ARCHIVEINFO_DIR;
	my $basedir = "/home/" . $user . "/" . ARCHIVEINFO_DIR . $jobname . "/";
	my $includelist = $basedir . INCLUDEFILE;
	my $include_childlist = $basedir .INCLUDE_CHILD;
	my $excludelist = $basedir .EXCLUDEFILE;
	my $jobfile = $basedir . JOBFILE;	

	mkdir $userdir, 0700 unless -d $userdir;
	mkdir $basedir, 0700 unless -d $basedir;

	open(my $fh_INCLUDE,">",$includelist) or die "Unable to open includelist ($includelist) for writing";
	chmod(0600, $fh_INCLUDE);
	close($fh_INCLUDE);

	open(my $fh_INCLUDECHILD,">",$include_childlist) or die "Unable to read includelist ($include_childlist)";
	chmod(0600, $fh_INCLUDECHILD);
	close($fh_INCLUDECHILD);

	open(my $fh_EXCLUDE,">",$excludelist) or die "Unable to open excludelist ($excludelist) for writing";
	chmod(0600, $fh_EXCLUDE);
	close($fh_EXCLUDE);

	open(my $fh_JOBFILE,">",$jobfile) or die "Unable to open excludelist ($excludelist) for writing";
	chmod(0600, $fh_JOBFILE);
	print $fh_JOBFILE "jobname = $jobname";
	close($fh_JOBFILE);

}

sub delete_job {

	my $user = $ARGV[1];
	my $jobname = $ARGV[2];

	my $jobdir = "/home/$user/".ARCHIVEINFO_DIR.$jobname;
	my $logdir = LOGDIR . $user."/".$jobname;
	my @cronfile;
	
	
	print("Removing $jobdir\n");
	rmtree($jobdir);
	print("Removing $logdir\n");
	rmtree($logdir);
	
	if(open(CRON,"<",CRON_FILE)) {
		@cronfile = <CRON>;
		close(CRON);
	}
	foreach my $line (@cronfile) {
		if( $line =~ m/$user\s+$jobname/ ) { 
			# correct user and jobname
			$line="";
			if(open(CRON,">",CRON_FILE)) {
				print CRON  @cronfile;
				close(CRON);
				print("Cronfile written.\n");
			} else {
				print("Error opening cronfile");
			}
			last;
		}
	}	
}

binmode(STDOUT, ":utf8");
binmode(STDIN, ":utf8");
#print "Enter backup system\n";


# Hash with all commands
# Key 	- name to use when called
# value	- function to be called and number of arguments
my %commands=(
	# User commands
	"backup" 	=> [\&run_backup,2],
	"addfiles" 	=> [\&add_files,3],         		# the filelist shall be contained as one argument within ""
	"removefiles" 	=> [\&rm_files,3],  				# the filelist shall be contained as one argument within ""
	"restorefiles" 	=> [\&restore_files,5], 		# File argument is one file/dir entry.
	"listjobs" 	=> [\&list_jobs,1], 						# Argument is username.
	"printschedule" 	=> [\&print_schedule,2], 	# Argument is username and jobname
	"writeschedule" 	=> [\&write_schedule,3], 	# Argument is username, jobname and schedule (within "" as "0 3 * * *")
	"createjob" 	=> [\&create_job,2], 					# Argument is username, jobname
	"deletejob" 	=> [\&delete_job,2], 					# Argument is username, jobname
	"get_currentfiles" => [\&get_lastsetinfo,2],# Argument is username, jobname
	
#	""	=> [\& ,],
);

if ((scalar(@ARGV))==0) {
   die "Not enough arguments";
}

my $args=scalar @ARGV-1;
my $cmd=$ARGV[0];

if($commands{$cmd} && $commands{$cmd}[1]==$args){

	my @includeglob;
	my @excludeglob;
	my @include_childglob;
	my $basedir;
	$commands{$cmd}[0]->(@ARGV[1..$args])==0 or exit 1;
}else{
	if(!$commands{$cmd}){
		die "Command $cmd not found";
	}else{
		die "Invalid parametercount for command $cmd";
	}
}




