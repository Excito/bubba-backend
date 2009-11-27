#!/usr/bin/perl -w

use strict;

package Bubba::Disk;

use Perl6::Say;
use JSON;
use threads;
use threads::shared;
use base qw(Net::Daemon);
use IPC::Run3;
use IPC::Open3;
use List::Util qw(min max);
use POSIX ":sys_wait_h";
use IPC::SysV qw(IPC_CREAT IPC_RMID S_IRUSR ftok);

use vars qw($exit);
use vars qw($VERSION);

$VERSION = '0.0.1';

use constant SOCKNAME		=> "/tmp/bubba-disk.socket";
use constant PIDFILE		=> '/tmp/bubba-disk.pid';
use constant MANAGER		=> '/usr/sbin/diskmanager';

my $IS_RUNNING : shared = 0;
my $DONE : shared = 0;
my $ERROR : shared = 0;
my $IS_IDLE : shared = 0;
my $STATUS_MESSAGE : shared = 0;
my $CURRENT_PROGRESS : shared = 0;
my $MAX_PROGRESS : shared = 1;
my $OVERALL_ACTION : shared = 'idle';
my $KILLPIDS : shared = &share([]);

sub new($$;$) {
	my($class, $attr, $args) = @_;
	my($self) = $class->SUPER::new($attr, $args);
	$self;
}

sub Loop($) {
	my ($self) = @_;
	if( $IS_RUNNING ) {
		$self->Debug("Loop: is still running");
		$IS_IDLE = 0;
		return;
	}
	$self->Debug("Loop: We are not running at the moment, idle for $IS_IDLE revolutions");
	if( ++$IS_IDLE >= 2 ) {
		$self->Log('notice', "Timeout: %s server terminating", ref($self));
		# cleaning up
		-f $self->{'pidfile'} and unlink $self->{'pidfile'};
		-S $self->{'localpath'} and unlink $self->{'localpath'};
		kill 'INT', $$;
	}
}

sub UserError($) {
	my $json = new JSON;
	my ($self, $err) = @_;
	$self->{'socket'}->say($json->encode({ error => "Error: $err" }));
	die( $err );
}

sub Run($) {
	my $json = new JSON;
	my ($self) = @_;
	my ($line,$sock);
	$sock = $self->{'socket'};
	while(1) {
		if (!defined($line = $sock->getline())) {
			if ($sock->error()) {
				$self->Error("Client connection error %s",
					$sock->error());
			}
			$sock->close();
			return;
		}
		$line =~ s/\s+$//; # Remove CRLF

		my $request;
		eval { $request = $json->decode($line) } || $self->Fatal("Unable to parse \"%s\": %s", $line, $!);
		if( exists $request->{action} ) {
			my $cmd = $request->{action};
			if( $cmd eq 'add_to_lvm' ) {
				$OVERALL_ACTION = 'extend_lvm';
				my $disk = $request->{disk} || $self->UserError("Missing parameter 'disk'");
				my $vg = $request->{vg} || $self->UserError("Missing parameter 'vg'");
				my $lv = $request->{lv} || $self->UserError("Missing parameter 'lv'");
				my $partition = "$disk"."1";
				my @cmd;
				my $err;
				my $cmd_str;
				$MAX_PROGRESS = 5;
				$CURRENT_PROGRESS = 0;
				$IS_RUNNING = 1;
				async {
					# Disk partition
					$STATUS_MESSAGE = "Partition disk $disk";
					@cmd = [ MANAGER, 'disk', 'partition', $disk, 'lvm' ];
					my( $stdout_buf, $stderr_buf );
					run3(@cmd, undef, \$stdout_buf, undef);

					eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

					if( exists $err->{status} and $err->{status} == 0 ) {
						$ERROR = 1;
						$cmd_str = join( ' ', @{$cmd[0]} );
						$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
						$IS_RUNNING = 0;
						return;
					}
					++$CURRENT_PROGRESS;
					sleep(5);

					# Creation of physical volume
					$STATUS_MESSAGE = "Creating physical volume for $partition";
					@cmd = [ MANAGER, 'lv', 'pvcreate', $partition ];
					run3(@cmd, undef, \$stdout_buf, undef);

					eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

					if( exists $err->{status} and $err->{status} == 0 ) {
						$ERROR = 1;
						$cmd_str = join( ' ', @{$cmd[0]} );
						$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
						$IS_RUNNING = 0;
						return;
					}
					++$CURRENT_PROGRESS;

					# Extension of volume group
					$STATUS_MESSAGE = "Extending volume group $vg";
					@cmd = [ MANAGER, 'lv', 'vgextend', $vg, $partition ];
					run3(@cmd, undef, \$stdout_buf, undef);

					eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

					if( exists $err->{status} and $err->{status} == 0 ) {
						$ERROR = 1;
						$cmd_str = join( ' ', @{$cmd[0]} );
						$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
						$IS_RUNNING = 0;
						return;
					}
					++$CURRENT_PROGRESS;

					# Extension of logical volume
					$STATUS_MESSAGE = "Extending logical volume $lv in the group $vg";
					@cmd = [ MANAGER, 'lv', 'lvextend', "/dev/$vg/$lv" ];
					run3(@cmd, undef, \$stdout_buf, undef);

					eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

					if( exists $err->{status} and $err->{status} == 0 ) {
						$ERROR = 1;
						$cmd_str = join( ' ', @{$cmd[0]} );
						$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
						$IS_RUNNING = 0;
						return;
					}
					++$CURRENT_PROGRESS;

					# Extension of the file system
					$STATUS_MESSAGE = "Extending the filesystem in volume $lv in the group $vg";
					@cmd = [ MANAGER, 'disk', 'extend', "/dev/$vg/$lv" ];
					run3(@cmd, undef, \$stdout_buf, undef);

					eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

					if( exists $err->{status} and $err->{status} == 0 ) {
						$ERROR = 1;
						$cmd_str = join( ' ', @{$cmd[0]} );
						$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
						$IS_RUNNING = 0;
						return;
					}
					++$CURRENT_PROGRESS;

					$IS_RUNNING = 0;
					$STATUS_MESSAGE = "Disk $disk has been sucessfully added to $vg-$lv";
					$DONE = 1;
					$OVERALL_ACTION = 'idle';
				};
				$sock->say( $json->encode( { done => $DONE, status => $STATUS_MESSAGE } ) );

			} elsif( $cmd eq 'create_raid_internal_lvm_external' ) {
				$OVERALL_ACTION = 'create_raid';
				my $level = $request->{level} || $self->UserError("Missing parameter 'level'");
				my $vg = "bubba"; # bubba
				my $lv = "storage"; # storage
				my $internal = "/dev/sda2"; # /dev/sda2
				my $mountpath = "/home"; # /home


				my @services = (
					[ 'cron', '/etc/init.d/cron' ],
					[ 'squeezecenter', '/etc/init.d/squeezecenter' ],
					[ 'mt-daapd', '/etc/init.d/mt-daapd' ],
					[ 'mediatomb', '/etc/init.d/mediatomb' ],
					[ 'proftpd', '/etc/init.d/proftpd' ],
					[ 'netatalk', '/etc/init.d/netatalk' ],
					[ 'cups', '/etc/init.d/cupsys' ],
					[ 'ftd', '/etc/init.d/filetransferdaemon' ],
					[ 'dovecot', '/etc/init.d/dovecot' ],
					[ 'fetchmail', '/etc/init.d/fetchmail' ],
					[ 'samba', '/etc/init.d/samba' ],
				);

				$MAX_PROGRESS = 18;
				$CURRENT_PROGRESS = 0;

				my $external_disk = $request->{external} || $self->UserError("Missing parameter 'external'");

				my $external = sprintf "%s%d", $external_disk, 1;

				$IS_RUNNING = 1;

				async {
					my( $stdout_buf, $stderr_buf );
					my @cmd;
					my $err;
					my @devices;
					my $vgs;
					my $cmd_str;

					{
						@cmd = [ MANAGER, 'fstab','is_mounted', $external ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);
						if( ref $err eq 'HASH' and $err->{mounted} ) {
							$STATUS_MESSAGE = "Umounting $external_disk"."1" ;
							@cmd = [ MANAGER, 'fstab','umount', $external  ];
							run3(@cmd, undef, \$stdout_buf, undef);

							eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

							if( exists $err->{status} and $err->{status} == 0 ) {
								$ERROR = 1;
								$cmd_str = join( ' ', @{$cmd[0]} );
								$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
								$IS_RUNNING = 0;
								return;
							};

							# Removal of fstab entry
							$STATUS_MESSAGE = "Removing FsTab entry for $external_disk"."1";
							@cmd = [ MANAGER, 'fstab','remove', $external ];
							run3(@cmd, undef, \$stdout_buf, undef);

							eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

							if( exists $err->{status} and $err->{status} == 0 ) {
								$ERROR = 1;
								$cmd_str = join( ' ', @{$cmd[0]} );
								$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
								$IS_RUNNING = 0;
								return;
							};

						}
						++$CURRENT_PROGRESS;
					}

					{
						# partition external
						$STATUS_MESSAGE = "Partition device $external_disk";
						@cmd = [ MANAGER, 'disk','partition', "$external_disk", "raid" ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};

						++$CURRENT_PROGRESS;
					}

					sleep(5);

					{
						# grab lvs
						@cmd = [ MANAGER, 'lv', 'list' ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $vgs = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						LOOP: foreach my $c_vg( @$vgs ) {
							if( $c_vg->{name} eq $vg ) {
								foreach my $c_lv( @{$c_vg->{lvs}} ) {
									if( $c_lv->{name} eq $lv ) {
										@devices = map {m#(/dev/\w+\d)#; $_=$1} @{$c_lv->{devices}};
										last LOOP;
									}
								}
							}
						}
						++$CURRENT_PROGRESS;
					}
					{
						# Shutting down services
						$STATUS_MESSAGE = "Terminating running services";


						my $nbr_substeps = scalar @services;
						my $cur_substep  = 0;
						my $old_current_progress = $CURRENT_PROGRESS;


						foreach ( @services ) {
							my( $service, $init_d ) = @$_;
							$CURRENT_PROGRESS = $old_current_progress + $cur_substep / $nbr_substeps;
							++$cur_substep;
							next unless -x $init_d;

							$STATUS_MESSAGE = "Terminating $service";
							system $init_d, 'stop';
						}

						$CURRENT_PROGRESS = $old_current_progress + 1;
					}

					{
						# Backing up the system
						$STATUS_MESSAGE = "Backup system";
						system 'mkdir', '/bkup';
						system 'mkdir', '/bkup/web';
						system 'mkdir', '/bkup/storage';
						system 'mkdir', '/bkup/storage/pictures';
						system 'mkdir', '/bkup/storage/music';
						system 'mkdir', '/bkup/storage/video';
						system 'mkdir', '/bkup/storage/extern';
						system 'chown', "nobody:users", "--recursive", "/bkup/storage";
						system 'chmod', "777", "--recursive", "/bkup/storage";
						system 'chown', "root:users", "/bkup/storage";
						system 'chown', "www-data:users", "/bkup/web";
						system 'chmod', "770", "/bkup/web";
						my @users;
						open PASSWD, '/etc/passwd';
						while (<PASSWD>) {
							my($uname,$x,$uid,$gid,$realname,$homedir,$shell) = split ':', $_;
							if( $uid >= 1000 && $uid < 65534 ) {
								system 'mkdir', "/bkup/$uname";
								system 'chmod', '755', "/bkup/$uname";
								foreach my $file ( glob( '/etc/skel/*' ) ) {
									system 'cp', '--recursive', $file, "/bkup/$uname";
								}
								system 'chown', "$uid:$gid", "--recursive", "/bkup/$uname";
								if ( -f "/home/$uname/.bubbacfg" ) {
									system 'cp', '--archive', "/home/$uname/.bubbacfg", "/bkup/$uname/.bubbacfg";
								}
							}

						}
						close PASSWD;

						++$CURRENT_PROGRESS;
					}

					{
						# Unmounting devices
						@cmd = [ MANAGER, 'fstab','is_mounted', "/dev/mapper/$vg-$lv" ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);
						if( ref $err eq 'HASH' and $err->{mounted} ) {
							$STATUS_MESSAGE = "Umounting $vg-$lv";
							@cmd = [ MANAGER, 'fstab','umount', "/dev/mapper/$vg-$lv" ];
							run3(@cmd, undef, \$stdout_buf, undef);

							eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

							if( exists $err->{status} and $err->{status} == 0 ) {
								$ERROR = 1;
								$cmd_str = join( ' ', @{$cmd[0]} );
								$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
								$IS_RUNNING = 0;
								return;
							};

							# Removal of fstab entry
							$STATUS_MESSAGE = "Removing FsTab entry for /dev/mapper/$vg-$lv";
							@cmd = [ MANAGER, 'fstab','remove', "/dev/mapper/$vg-$lv" ];
							run3(@cmd, undef, \$stdout_buf, undef);

							eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

							if( exists $err->{status} and $err->{status} == 0 ) {
								$ERROR = 1;
								$cmd_str = join( ' ', @{$cmd[0]} );
								$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
								$IS_RUNNING = 0;
								return;
							};

						} else {
							@cmd = [ MANAGER, 'fstab','is_mounted', "/dev/$vg/$lv" ];
							run3(@cmd, undef, \$stdout_buf, undef);

							eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);
							if( ref $err eq 'HASH' and $err->{mounted} ) {
								$STATUS_MESSAGE = "Umounting $vg-$lv";
								@cmd = [ MANAGER, 'fstab','umount', "/dev/$vg/$lv" ];
								run3(@cmd, undef, \$stdout_buf, undef);

								eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

								if( exists $err->{status} and $err->{status} == 0 ) {
									$ERROR = 1;
									$cmd_str = join( ' ', @{$cmd[0]} );
									$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
									$IS_RUNNING = 0;
									return;
								};

								# Removal of fstab entry
								$STATUS_MESSAGE = "Removing FsTab entry for /dev/$vg/$lv";
								@cmd = [ MANAGER, 'fstab','remove', "/dev/$vg/$lv" ];
								run3(@cmd, undef, \$stdout_buf, undef);

								eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

								if( exists $err->{status} and $err->{status} == 0 ) {
									$ERROR = 1;
									$cmd_str = join( ' ', @{$cmd[0]} );
									$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
									$IS_RUNNING = 0;
									return;
								};

							}
						}

						++$CURRENT_PROGRESS;
					}

					{
						# Removal of logical volume
						$STATUS_MESSAGE = "Removing logical volume $vg-$lv";
						@cmd = [ MANAGER, 'lv','lvremove', "/dev/$vg/$lv" ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};

						++$CURRENT_PROGRESS;
					}

					{
						# Removing volume group
						$STATUS_MESSAGE = "Removing volume group $vg";
						@cmd = [ MANAGER, 'lv','vgremove', "$vg" ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};

						++$CURRENT_PROGRESS;
					}
					{
						# Revoval of Physical volume devices
						foreach my $partition( @devices ) {
							$STATUS_MESSAGE = "Removing physical volume $partition";
							@cmd = [ MANAGER, 'lv','pvremove', "$partition" ];
							my( $stdout_buf, $stderr_buf );
							run3(@cmd, undef, \$stdout_buf, undef);

							eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

							if( exists $err->{status} and $err->{status} == 0 ) {
								$ERROR = 1;
								$cmd_str = join( ' ', @{$cmd[0]} );
								$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
								$IS_RUNNING = 0;
								return;
							};
						}

						++$CURRENT_PROGRESS;
					}

					{
						# update internal partition table
						$STATUS_MESSAGE = "Updating internal partition type";
						@cmd = [ MANAGER, 'disk','set_partition_type', "$internal", "raid" ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};

						++$CURRENT_PROGRESS;
					}

					my $nextmd;
					my $partitions;
					{
						# Find the top most device, if any
						$STATUS_MESSAGE = "Querying bext MD device name";
						@cmd = [ MANAGER, 'md','get_next_md' ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( ref $err eq 'HASH' and exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};

						$nextmd = $err->{nextmd};

						$partitions = [ $internal, $external ];

						++$CURRENT_PROGRESS;
					}
					{
						# Creating RAID array
						$STATUS_MESSAGE = "Creating RAID array $nextmd";
						@cmd = [ MANAGER, 'md','create', $level, scalar @$partitions, 0, @$partitions, $nextmd ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};

						++$CURRENT_PROGRESS;
					}

					# TODO
					# uppdatera mdadm.conf

					{
						# Format the RAID array

						$STATUS_MESSAGE = "Format RAID array $nextmd";
						@cmd = [ MANAGER, 'disk','format', $nextmd, 'ext3' ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};

						++$CURRENT_PROGRESS;
					}
					{
						# Setup FsTab
						$STATUS_MESSAGE = "Setting up FsTab";
						@cmd = [ MANAGER, 'fstab','add', $nextmd, $mountpath, 'auto', 'defaults', 0, 2 ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};
						++$CURRENT_PROGRESS;
					}
					{
						# Mount
						$STATUS_MESSAGE = "Mounting $mountpath";
						@cmd = [ MANAGER, 'fstab','mount', $nextmd ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};
						++$CURRENT_PROGRESS;
					}
					{
						# Restore the previous backup
						$STATUS_MESSAGE = "Restoring backup";
						system 'cp', '--archive', '--recursive', glob('/bkup/*'), '/home';
						system 'rm', '-rf', '/bkup';

						++$CURRENT_PROGRESS;
					}
					{
						# Restore default web page
						$STATUS_MESSAGE = "Restore the default web page";
						system 'cp', '-a', glob('/usr/share/bubba-backend/default_web/*'), '/home/web';
						system 'chown', 'www-data:users', '/home/web';

						++$CURRENT_PROGRESS;
					}

					{
						# Restarting services
						$STATUS_MESSAGE = "Restarting shut down services";


						my $nbr_substeps = scalar @services;
						my $cur_substep  = 0;
						my $old_current_progress = $CURRENT_PROGRESS;


						foreach ( reverse @services ) {
							my( $service, $init_d ) = @$_;
							$CURRENT_PROGRESS = $old_current_progress + $cur_substep / $nbr_substeps;
							++$cur_substep;
							next unless -x $init_d;

							$STATUS_MESSAGE = "Restarting $service";
							system $init_d, 'start';
						}

						$CURRENT_PROGRESS = $old_current_progress + 1;
					}

					$IS_RUNNING = 0;
					$STATUS_MESSAGE = "Conversion to RAID-$level complete";
					$DONE = 1;
					$OVERALL_ACTION = 'idle';
				};


				$sock->say( $json->encode( { done => $DONE, status => $STATUS_MESSAGE } ) );

			} elsif( $cmd eq 'restore_raid_broken_external' ) {
				$OVERALL_ACTION = 'restore_raid';
				my $disk = $request->{disk} || $self->UserError("Missing parameter 'disk'");
				my $external = "${disk}1";
				my $md = "/dev/md0"; # autodetect?;
				$MAX_PROGRESS = 2;
				$CURRENT_PROGRESS = 0;
				$IS_RUNNING = 1;

				async {
					my( $stdout_buf, $stderr_buf );
					my @cmd;
					my $err;
					my @devices;
					my $vgs;
					my $cmd_str;


					{
						# partition external disk
						$STATUS_MESSAGE = "Partition external disk";
						@cmd = [ MANAGER, 'disk','partition', "$disk", "raid" ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};

						++$CURRENT_PROGRESS;
					}
					sleep(5);

					my $nextmd;
					my $partitions;
					{
						$STATUS_MESSAGE = "Adding external disk to array";
						@cmd = [ MANAGER, 'md','add', $md, $external ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};

						++$CURRENT_PROGRESS;
					}

					$IS_RUNNING = 0;
					$STATUS_MESSAGE = "The new disk has successfully been added. Synchronizing disks in progress.";
					$DONE = 1;

					$OVERALL_ACTION = 'idle';
				};

				$sock->say( $json->encode( { done => $DONE, status => $STATUS_MESSAGE } ) );

			} elsif( $cmd eq 'restore_raid_broken_internal' ) {
				$OVERALL_ACTION = 'restore_raid';

				my $vg = "bubba"; # bubba
				my $lv = "storage"; # storage
				my $internal = "/dev/sda2"; # /dev/sda2
				my $mountpath = "/home"; # /home
				my $md = "/dev/md0"; #autodetect?
				my $disk = $request->{disk} || $self->UserError("Missing parameter 'disk'");
				my $part = $request->{partition} || $self->UserError("Missing parameter 'partition'");
				my $external = "${disk}${part}";

				my @services = (
					[ 'cron', '/etc/init.d/cron' ],
					[ 'squeezecenter', '/etc/init.d/squeezecenter' ],
					[ 'mt-daapd', '/etc/init.d/mt-daapd' ],
					[ 'mediatomb', '/etc/init.d/mediatomb' ],
					[ 'proftpd', '/etc/init.d/proftpd' ],
					[ 'netatalk', '/etc/init.d/netatalk' ],
					[ 'cups', '/etc/init.d/cupsys' ],
					[ 'ftd', '/etc/init.d/filetransferdaemon' ],
					[ 'dovecot', '/etc/init.d/dovecot' ],
					[ 'fetchmail', '/etc/init.d/fetchmail' ],
					[ 'samba', '/etc/init.d/samba' ],
				);
				$MAX_PROGRESS = 12;
				$CURRENT_PROGRESS = 0;
				$IS_RUNNING = 1;

				async {
					my( $stdout_buf, $stderr_buf );
					my @cmd;
					my $err;
					my @devices;
					my $vgs;
					my $cmd_str;
					{
						# grab lvs
						@cmd = [ MANAGER, 'lv', 'list' ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $vgs = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						foreach my $c_vg( @$vgs ) {
							if( $c_vg->{name} eq $vg ) {
								foreach my $c_lv( @{$c_vg->{lvs}} ) {
									if( $c_lv->{name} eq $lv ) {
										@devices = map {m#(/dev/\w+\d)#; $_=$1} @{$c_lv->{devices}};
									}
								}
							}
						}
						++$CURRENT_PROGRESS;
					}
					{
						# Shutting down services
						$STATUS_MESSAGE = "Terminating running services";


						my $nbr_substeps = scalar @services;
						my $cur_substep  = 0;
						my $old_current_progress = $CURRENT_PROGRESS;


						foreach ( @services ) {
							my( $service, $init_d ) = @$_;
							$CURRENT_PROGRESS = $old_current_progress + $cur_substep / $nbr_substeps;
							++$cur_substep;
							next unless -x $init_d;

							$STATUS_MESSAGE = "Terminating $service";
							system $init_d, 'stop';
						}

						$CURRENT_PROGRESS = $old_current_progress + 1;
					}

					{
						# Unmounting devices
						@cmd = [ MANAGER, 'fstab','is_mounted', "/dev/mapper/$vg-$lv" ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);
						if( ref $err eq 'HASH' and $err->{mounted} ) {
							$STATUS_MESSAGE = "Umounting $vg-$lv";
							@cmd = [ MANAGER, 'fstab','umount', "/dev/mapper/$vg-$lv" ];
							run3(@cmd, undef, \$stdout_buf, undef);

							eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

							if( exists $err->{status} and $err->{status} == 0 ) {
								$ERROR = 1;
								$cmd_str = join( ' ', @{$cmd[0]} );
								$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
								$IS_RUNNING = 0;
								return;
							};

							# Removal of fstab entry
							$STATUS_MESSAGE = "Removing FsTab entry for /dev/mapper/$vg-$lv";
							@cmd = [ MANAGER, 'fstab','remove', "/dev/mapper/$vg-$lv" ];
							run3(@cmd, undef, \$stdout_buf, undef);

							eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

							if( exists $err->{status} and $err->{status} == 0 ) {
								$ERROR = 1;
								$cmd_str = join( ' ', @{$cmd[0]} );
								$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
								$IS_RUNNING = 0;
								return;
							};

						} else {
							@cmd = [ MANAGER, 'fstab','is_mounted', "/dev/$vg/$lv" ];
							run3(@cmd, undef, \$stdout_buf, undef);

							eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);
							if( ref $err eq 'HASH' and $err->{mounted} ) {
								$STATUS_MESSAGE = "Umounting $vg-$lv";
								@cmd = [ MANAGER, 'fstab','umount', "/dev/$vg/$lv" ];
								run3(@cmd, undef, \$stdout_buf, undef);

								eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

								if( exists $err->{status} and $err->{status} == 0 ) {
									$ERROR = 1;
									$cmd_str = join( ' ', @{$cmd[0]} );
									$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
									$IS_RUNNING = 0;
									return;
								};

								# Removal of fstab entry
								$STATUS_MESSAGE = "Removing FsTab entry for /dev/$vg/$lv";
								@cmd = [ MANAGER, 'fstab','remove', "/dev/$vg/$lv" ];
								run3(@cmd, undef, \$stdout_buf, undef);

								eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

								if( exists $err->{status} and $err->{status} == 0 ) {
									$ERROR = 1;
									$cmd_str = join( ' ', @{$cmd[0]} );
									$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
									$IS_RUNNING = 0;
									return;
								};

							}
						}

						@cmd = [ MANAGER, 'fstab','is_mounted', $external ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);
						if( ref $err eq 'HASH' and $err->{mounted} ) {
							$STATUS_MESSAGE = "Umounting $external" ;
							@cmd = [ MANAGER, 'fstab','umount', $external  ];
							run3(@cmd, undef, \$stdout_buf, undef);

							eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

							if( exists $err->{status} and $err->{status} == 0 ) {
								$ERROR = 1;
								$cmd_str = join( ' ', @{$cmd[0]} );
								$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
								$IS_RUNNING = 0;
								return;
							};

							# Removal of fstab entry
							$STATUS_MESSAGE = "Removing FsTab entry for $external";
							@cmd = [ MANAGER, 'fstab','remove', $external ];
							run3(@cmd, undef, \$stdout_buf, undef);

							eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

							if( exists $err->{status} and $err->{status} == 0 ) {
								$ERROR = 1;
								$cmd_str = join( ' ', @{$cmd[0]} );
								$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
								$IS_RUNNING = 0;
								return;
							};

						}

						++$CURRENT_PROGRESS;
					}
					{
						# Removal of logical volume
						$STATUS_MESSAGE = "Removing logical volume $vg-$lv";
						@cmd = [ MANAGER, 'lv','lvremove', "/dev/$vg/$lv" ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};

						++$CURRENT_PROGRESS;
					}
					{
						# Removing volume group
						$STATUS_MESSAGE = "Removing volume group $vg";
						@cmd = [ MANAGER, 'lv','vgremove', "$vg" ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};

						++$CURRENT_PROGRESS;
					}
					{
						# Revoval of Physical volume devices
						foreach my $partition( @devices ) {
							$STATUS_MESSAGE = "Removing physical volume $partition";
							@cmd = [ MANAGER, 'lv','pvremove', "$partition" ];
							my( $stdout_buf, $stderr_buf );
							run3(@cmd, undef, \$stdout_buf, undef);

							eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

							if( exists $err->{status} and $err->{status} == 0 ) {
								$ERROR = 1;
								$cmd_str = join( ' ', @{$cmd[0]} );
								$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
								$IS_RUNNING = 0;
								return;
							};
						}

						++$CURRENT_PROGRESS;
					}

					{
						# update internal partition table
						$STATUS_MESSAGE = "Updating internal partition type";
						@cmd = [ MANAGER, 'disk','set_partition_type', "$internal", "raid" ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};

						++$CURRENT_PROGRESS;
					}

					# wait for partition update
					sleep 5;

					my $partitions;

					{
						$STATUS_MESSAGE = "Assemble degraded array $md";
						@cmd = [ MANAGER, 'md','assemble', $md, $external ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};

						++$CURRENT_PROGRESS;
					}

					sleep 5;
					{
						$STATUS_MESSAGE = "Add internal partition as spare to $md";
						@cmd = [ MANAGER, 'md','add', $md, $internal ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};

						++$CURRENT_PROGRESS;
					}
					{
						# Setup FsTab
						$STATUS_MESSAGE = "Setting up FsTab";
						@cmd = [ MANAGER, 'fstab','add', $md, $mountpath, 'auto', 'defaults', 0, 2 ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};
						++$CURRENT_PROGRESS;
					}
					{
						# Mount
						$STATUS_MESSAGE = "Mounting $mountpath";
						@cmd = [ MANAGER, 'fstab','mount', $md ];
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							$cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						};
						++$CURRENT_PROGRESS;
					}
					{
						# Restarting services
						$STATUS_MESSAGE = "Restarting shut down services";


						my $nbr_substeps = scalar @services;
						my $cur_substep  = 0;
						my $old_current_progress = $CURRENT_PROGRESS;


						foreach ( reverse @services ) {
							my( $service, $init_d ) = @$_;
							$CURRENT_PROGRESS = $old_current_progress + $cur_substep / $nbr_substeps;
							++$cur_substep;
							next unless -x $init_d;

							$STATUS_MESSAGE = "Restarting $service";
							system $init_d, 'start';
						}

						$CURRENT_PROGRESS = $old_current_progress + 1;
					}

					$IS_RUNNING = 0;
					$STATUS_MESSAGE = "$md has been sucessfully restored, full sync will be achieved after a few hours";
					$DONE = 1;
					$OVERALL_ACTION = 'idle';
				};

				$sock->say( $json->encode( { done => $DONE, status => $STATUS_MESSAGE } ) );

			} elsif( $cmd eq 'format_disk' ) {
				$OVERALL_ACTION = 'format';
				my $disk = $request->{disk} || $self->UserError("Missing parameter 'disk'");
				my $label = $request->{label} || $self->UserError("Missing parameter 'label'");
				my $partition = "$disk"."1";
				$MAX_PROGRESS = 100;
				$CURRENT_PROGRESS = 0;
				$IS_RUNNING = 1;
				async {
					{
						# Disk partition
						$STATUS_MESSAGE = "Partition disk $disk";
						my @cmd = [ MANAGER, 'disk', 'partition', $disk, 'raw', $label ];
						my( $err, $stdout_buf, $stderr_buf );
						run3(@cmd, undef, \$stdout_buf, undef);

						eval { $err = $json->decode($stdout_buf) } || $self->Fatal("Unable to parse \"%s\": %s", $stdout_buf, $!);

						if( exists $err->{status} and $err->{status} == 0 ) {
							$ERROR = 1;
							my $cmd_str = join( ' ', @{$cmd[0]} );
							$STATUS_MESSAGE = "Error: $err->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						}
						$CURRENT_PROGRESS = 10;
					}
					sleep 5; 
					# while the partitions might have been completed, it can take an second or five to sync it
					# so we sleep for 5 secs to make sure it's synced. (this will especially happen for small 
					# USB memory sticks)

					{
						# Disk format
						$STATUS_MESSAGE = "Format disk $disk";
						my $cmd = [ MANAGER, 'disk', 'format', "${disk}1", 'ext3' ];
						my($wtr, $rdr, $err, $buf);
						my $pid = open3($wtr, $rdr, $err, @$cmd );
						my $token =  ftok( '/tmp/dmgshm', $pid );
						if( my $sid = shmget( $token, 4096,  S_IRUSR | IPC_CREAT ) ) {
							while( waitpid( $pid, WNOHANG ) != -1 ) {
								shmread($sid, $buf, 0, 4096);
								substr($buf, index($buf, "\0")) = '';
								$CURRENT_PROGRESS = 10 + $buf * .8 if $buf;
								sleep(1);
							}
							shmctl( $sid, IPC_RMID, 0);
						} else {

							waitpid( $pid, 0 );
						}

						my $json_str;
						my $output = <$rdr>;

						eval { $json_str = $json->decode($output) } || $self->Fatal("Unable to parse \"%s\": %s", $output, $!);

						if( exists $json_str->{status} and $json_str->{status} == 0 ) {
							$ERROR = 1;
							my $cmd_str = join( ' ', @$cmd );
							$STATUS_MESSAGE = "Error: $json_str->{errmsg}: $cmd_str";
							$IS_RUNNING = 0;
							return;
						}
						$CURRENT_PROGRESS = 90;
					}
					sleep 5; 
					# we'll sleep again before we really sync the new stuff.
					{
						system( MANAGER, 'disk', 'probe', $disk );
						$CURRENT_PROGRESS = 95;
					}
					{
						# Tuning filesystem
						# TODO move to diskmanager
						$STATUS_MESSAGE = "Tuning disk $disk";
						my $cmd = [ 'tune2fs', '-c', 0, '-i', 0, "${disk}1" ];
						my ($in, $out, $err);
						run3 $cmd, \$in,  \$out, \$err;
						$CURRENT_PROGRESS = 100;
					}

					$IS_RUNNING = 0;
					$STATUS_MESSAGE = "$disk has been sucessfully formated";
					$DONE = 1;
					$OVERALL_ACTION = 'idle';
				}

				$sock->say( $json->encode( { done => $DONE, status => $STATUS_MESSAGE } ) );

			} elsif( $cmd eq 'progress' ) {
				$sock->say( $json->encode( { done => $DONE, status => $STATUS_MESSAGE, progress => sprintf("%.2f", $CURRENT_PROGRESS / $MAX_PROGRESS * 100  ) } ) );
			} elsif( $cmd eq 'status' ) {
				$sock->say( $json->encode( { status => $OVERALL_ACTION } ) );
			} elsif( $cmd eq 'shutdown' ) {
				$self->Log('notice', "Asked %s to be shutdown", ref($self));

				foreach my $pid ( @$KILLPIDS ) {
					$self->Log('notice', "Killed %s", $pid);
					kill 'KILL', $pid;
				}
				# cleaning up
				-f $self->{'pidfile'} and unlink $self->{'pidfile'};
				-S $self->{'localpath'} and unlink $self->{'localpath'};
				kill 'INT', $$;
			}
		}
	}
}

package main;


my $server = new Bubba::Disk({
		localpath => Bubba::Disk::SOCKNAME, 
		pidfile => Bubba::Disk::PIDFILE,
		'loop-timeout' => 30, 
	}, \@ARGV);
$server->Bind();
