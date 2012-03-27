#!/usr/bin/perl -w

use strict;

use v5.10;

use Proc::Daemon;

use Sys::Syslog;

use File::Slurp;

use IO::Async::Function;
use IO::Async::Stream;
use IO::Async::Loop;
use IO::Async::Listener;
use IO::Async::Timer::Periodic;
use IO::Async::Timer::Countdown;

use IPC::Shareable;
use IPC::Run3;
use IPC::Open3;

use JSON;
use Try::Tiny;

use POSIX ":sys_wait_h";
use IPC::SysV qw(IPC_CREAT IPC_RMID S_IRUSR ftok);

use constant SOCKNAME		=> "/tmp/bubba-disk.socket";
use constant PIDFILE		=> '/tmp/bubba-disk.pid';
use constant MANAGER		=> '/usr/sbin/diskmanager';
use constant DELAY          => 20;

my $daemon = Proc::Daemon->new(
    work_dir => '/',
    pid_file => PIDFILE
);

$daemon->Init();
openlog('bubba-diskdaemon', "", "user");
syslog("info", "Starting up");
my $ppid = $$;
my %status;
tie %status, 'IPC::Shareable', $ppid, {
    create => 'yes',
    mode => 0666,
    destroy => 'yes'
} or die "tie failed, stopped";

my $is_running = 0;

%status = (
    overall_action => 'idle',
    idle => 0,
    progress => 0,
    done => 0,
    error => 0
);

sub reset_status {
    $status{overall_action} = 'idle';
    $status{is_idle} = 0;
    $status{progress} = 0;
    $status{done} = 0;
    $status{error} = 0;
}

my $loop = IO::Async::Loop->new;

sub HUNTSMAN {

    syslog("info", "shutting down");
    IPC::Shareable->clean_up;
    $loop->loop_stop;
    unlink PIDFILE;
    unlink SOCKNAME;
    $daemon->Kill_Daemon();
}

$SIG{INT} = \&HUNTSMAN;

unlink SOCKNAME;


my $listener;

sub write_progress {
    my($stream)= @_;
    $stream->write(
        encode_json(
            {
                done => $status{done},
                status => $status{status},
                progress => sprintf("%.2f", $status{progress})
            }
        )
    );

}

$listener = IO::Async::Listener->new(
    on_stream => sub {
        my ( undef, $stream ) = @_;

        $stream->configure(
            autoflush => 1,
            on_read => sub {
                my ( $self, $buffref, $eof ) = @_;
                my $data = $$buffref;
                $data =~ s/\s+$//;
                my $request;
                if(eval { $request = decode_json $data }) {
                    $$buffref = "";
                    given($request->{action}) {
                        when('add_to_lvm') {
                            if($is_running) {
                                $stream->write(encode_json({ error => "allready running" })."\n");
                                return;
                            }
                            $is_running = 1;
                            try {
                                my $disk = $request->{disk} || die("Missing parameter 'disk'");
                                my $vg = $request->{vg} || die("Missing parameter 'vg'");
                                my $lv = $request->{lv} || die("Missing parameter 'lv'");
                                my $partition = "$disk"."1";

                                my $function = IO::Async::Function->new(
                                    code => \&add_to_lvm
                                );

                                $loop->add( $function );

                                $function->call(
                                    args => [$disk, $vg, $lv, $partition],
                                    on_return => sub {
                                        syslog("info", "returning from add_to_lvm");
                                        $is_running = 0;
                                        $function->stop;
                                    },
                                    on_error => sub {
                                        $is_running = 0;
                                        $function->stop;
                                        die $_[0];
                                    },
                                );
                            } catch {
                                $stream->write(encode_json({ error => "Caught error: $_[0]" })."\n");
                                $is_running = 0;
                                syslog('error',"Caught error: %s",$_[0]);
                            } finally {
                                write_progress($stream) unless $@;
                            }
                        }
                        when('create_raid_internal_lvm_external') {
                            if($is_running) {
                                $stream->write(encode_json({ error => "allready running" })."\n");
                                return;
                            }
                            $is_running = 1;
                            try {
                                my $level = $request->{level} || die("Missing parameter 'level'");
                                my $external_disk = $request->{external} || die("Missing parameter 'external'");

                                my $function = IO::Async::Function->new(
                                    code => \&create_raid
                                );

                                $loop->add( $function );

                                $function->call(
                                    args => [$level, $external_disk],
                                    on_return => sub {
                                        syslog("info", "returning from create_raid");
                                        $is_running = 0;
                                        $function->stop;
                                    },
                                    on_error => sub {
                                        $is_running = 0;
                                        $function->stop;
                                        die $_[0];
                                    },
                                );
                            } catch {
                                $stream->write(encode_json({ error => "Caught error: $_[0]" })."\n");
                                $is_running = 0;
                                syslog('error',"Caught error: %s",$_[0]);
                            } finally {
                                write_progress($stream) unless $@;
                            }

                        }
                        when('restore_raid_broken_external'){
                            if($is_running) {
                                $stream->write(encode_json({ error => "allready running" })."\n");
                                return;
                            }
                            $is_running = 1;
                            try {
                                my $disk = $request->{disk} || die("Missing parameter 'disk'");

                                my $function = IO::Async::Function->new(
                                    code => \&restore_raid_broken_external
                                );

                                $loop->add( $function );

                                $function->call(
                                    args => [$disk],
                                    on_return => sub {
                                        syslog("info", "returning from restore_raid_broken_external");
                                        $is_running = 0;
                                        $function->stop;
                                    },
                                    on_error => sub {
                                        $is_running = 0;
                                        $function->stop;
                                        die $_[0];
                                    },
                                );

                            } catch {
                                $stream->write(encode_json({ error => "Caught error: $_[0]" })."\n");
                                $is_running = 0;
                                syslog('error',"Caught error: %s",$_[0]);
                            } finally {
                                write_progress($stream) unless $@;
                            }

                        }
                        when('restore_raid_broken_internal') {
                            if($is_running) {
                                $stream->write(encode_json({ error => "allready running" })."\n");
                                return;
                            }
                            $is_running = 1;
                            try {
                                my $disk = $request->{disk} || die("Missing parameter 'disk'");
                                my $part = $request->{partition} || die("Missing parameter 'partition'");

                                my $function = IO::Async::Function->new(
                                    code => \&restore_raid_broken_internal
                                );

                                $loop->add( $function );

                                $function->call(
                                    args => [$disk, $part],
                                    on_return => sub {
                                        syslog("info", "returning from restore_raid_broken_internal");
                                        $is_running = 0;
                                        $function->stop;
                                    },
                                    on_error => sub {
                                        $is_running = 0;
                                        $function->stop;
                                        die $_[0];
                                    },
                                );

                            } catch {
                                $stream->write(encode_json({ error => "Caught error: $_[0]" })."\n");
                                $is_running = 0;
                                syslog('error',"Caught error: %s",$_[0]);
                            } finally {
                                write_progress($stream) unless $@;
                            }


                        }
                        when('format_disk') {
                            if($is_running) {
                                $stream->write(encode_json({ error => "allready running" })."\n");
                                return;
                            }
                            $is_running = 1;
                            try {
                                my $disk = $request->{disk} || die("Missing parameter 'disk'");
                                my $label = $request->{label} || die("Missing parameter 'label'");

                                my $function = IO::Async::Function->new(
                                    code => \&format_disk
                                );

                                $loop->add( $function );

                                $function->call(
                                    args => [$disk, $label],
                                    on_return => sub {
                                        syslog("info", "returning from format_disk");
                                        $is_running = 0;
                                        $function->stop;
                                    },
                                    on_error => sub {
                                        $is_running = 0;
                                        $function->stop;
                                        die $_[0];
                                    },
                                );

                            } catch {
                                $stream->write(encode_json({ error => "Caught error: $_[0]" })."\n");
                                $is_running = 0;
                                syslog('error', "Caught error: %s", $_[0]);
                            } finally {
                                write_progress($stream) unless $@;
                            }

                        }
                        when('progress') {
                            try {
                                $stream->write(
                                    encode_json(
                                        {
                                            done => $status{done},
                                            status => $status{status},
                                            progress => sprintf("%.2f", $status{progress})
                                        }
                                    )
                                );
                            } catch {
                                $stream->write(encode_json({ error => "Caught error: $_[0]" })."\n");
                                syslog('error', "Caught error: %s", $_[0]);
                            }
                        }
                        when('status') {
                            try {
                                $stream->write(
                                    encode_json(
                                        {
                                            status => $status{overall_action}
                                        }
                                    )
                                );
                            } catch {
                                $stream->write(encode_json({ error => "Caught error: $_[0]" })."\n");
                                syslog('error', "Caught error: %s", $_[0]);
                            }
                        }
                    }
                }
                $stream->write("\n");
                return 0;
            },
            read_all => 1,
        );

        $loop->add( $stream );
    },
);

$loop->add( $listener );

$listener->listen(
    addr => {
        family => "unix",
        socktype => "stream",
        path => SOCKNAME
    },
    on_resolve_error => sub { print STDERR "Cannot resolve - $_[0]\n"; },
    on_listen_error  => sub { print STDERR "Cannot listen\n"; },
);

my $timer;
$timer = IO::Async::Timer::Periodic->new(
    interval => DELAY,
    first_interval => DELAY * 3,

    on_tick => sub {
        unless($is_running) {
            syslog("info", "Idle timer encountered");
            my $countdown = IO::Async::Timer::Countdown->new(
                delay => DELAY/2,

                on_expire => sub {
                    unless($is_running) {
                        $timer->stop;
                        &HUNTSMAN;
                    } else {
                        syslog("info", "we wasn't idle...");
                    }
                },
            );
            $countdown->start;
            $loop->add( $countdown );
        }
    },
);

$timer->start;

$loop->add( $timer );

$loop->loop_forever;

sub progress {
    my( $current, $max ) = @_;
    $status{progress} = ($current / $max ) * 100;
}

sub add_to_lvm {
    my($disk, $vg, $lv, $partition) = @_;
    try {
        reset_status();
        $status{overall_action} = 'add_to_lvm';

        my @cmd;
        my $err;
        my $cmd_str;
        $status{progress} = 0;

        # Disk partition
        $status{status} = "Partition disk $disk";

        @cmd = [ MANAGER, 'disk', 'partition', $disk, 'lvm' ];
        my( $stdout_buf, $stderr_buf );
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            $status{error} = 1;
            $cmd_str = join( ' ', @{$cmd[0]} );
            $status{status} = "Error: $err->{errmsg}: $cmd_str";
            return;
        }
        $status{progress} = 20;
        sleep(5);

        # Creation of physical volume
        $status{status} = "Creating physical volume for $partition";
        @cmd = [ MANAGER, 'lv', 'pvcreate', $partition ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            $status{error} = 1;
            $cmd_str = join( ' ', @{$cmd[0]} );
            $status{status} = "Error: $err->{errmsg}: $cmd_str";
            return;
        }
        $status{progress} = 40;

        # Extension of volume group
        $status{status} = "Extending volume group $vg";

        @cmd = [ MANAGER, 'lv', 'vgextend', $vg, $partition ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            $status{error} = 1;
            $cmd_str = join( ' ', @{$cmd[0]} );
            $status{status} = "Error: $err->{errmsg}: $cmd_str";
            return;
        }
        $status{progress} = 60;

        # Extension of logical volume
        $status{status} = "Extending logical volume $lv in the group $vg";
        @cmd = [ MANAGER, 'lv', 'lvextend', "/dev/$vg/$lv" ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            $status{error} = 1;
            $cmd_str = join( ' ', @{$cmd[0]} );
            $status{status} = "Error: $err->{errmsg}: $cmd_str";
            return;
        }
        $status{progress} = 80;

        # Extension of the file system
        $status{status} = "Extending the filesystem in volume $lv in the group $vg";
        @cmd = [ MANAGER, 'disk', 'extend', "/dev/$vg/$lv" ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            $status{error} = 1;
            $cmd_str = join( ' ', @{$cmd[0]} );
            $status{status} = "Error: $err->{errmsg}: $cmd_str";
            return;
        }
        $status{progress} = 100;

        $status{status} = "Disk $disk has been sucessfully added to $vg-$lv";
        $status{done} = 1;
    } catch {
        $status{done} = 1;
        $status{error} = 1;
        $status{status} = "Caught error: $_[0]";
    }
    $is_running = 0;
    $status{overall_action} = 'idle';
    return;
}

sub create_raid {
    my($level, $external_disk) = @_;
    try {
        reset_status();
        $status{overall_action} = 'create_raid';

        my $steps = 20;


        my $vg = "bubba"; # bubba
        my $lv = "storage"; # storage
        my $internal = "/dev/sda2"; # /dev/sda2
        my $mountpath = "/home"; # /home


        my @services = (
            [ 'cron', '/etc/init.d/cron' ],
            [ 'logitechmediaserver', '/etc/init.d/logitechmediaserver' ],
            [ 'forked-daapd', '/etc/init.d/forked-daapd' ],
            [ 'minidlna', '/etc/init.d/minidlna' ],
            [ 'proftpd', '/etc/init.d/proftpd' ],
            [ 'netatalk', '/etc/init.d/netatalk' ],
            [ 'cups', '/etc/init.d/cupsys' ],
            [ 'ftd', '/etc/init.d/filetransferdaemon' ],
            [ 'dovecot', '/etc/init.d/dovecot' ],
            [ 'fetchmail', '/etc/init.d/fetchmail' ],
            [ 'samba', '/etc/init.d/samba' ],
        );

        progress(0, $steps);


        my $external = sprintf "%s%d", $external_disk, 1;

        my( $stdout_buf, $stderr_buf );
        my @cmd;
        my $err;
        my @devices;
        my $vgs;
        my $cmd_str;

        # workaround for parted when modifying partition table
        system('swapoff', '/dev/sda3');

        @cmd = [ MANAGER, 'fstab','is_mounted', $external ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);
        if( ref $err eq 'HASH' and $err->{mounted} ) {
            $status{status} = "Umounting $external_disk"."1" ;
            @cmd = [ MANAGER, 'fstab','umount', $external  ];
            run3(@cmd, undef, \$stdout_buf, undef);

            $err = decode_json($stdout_buf);

            if( exists $err->{status} and $err->{status} == 0 ) {
                die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
            };

            # Removal of fstab entry
            $status{status} = "Removing FsTab entry for $external_disk"."1";
            @cmd = [ MANAGER, 'fstab','remove', $external ];
            run3(@cmd, undef, \$stdout_buf, undef);

            $err = decode_json($stdout_buf);

            if( exists $err->{status} and $err->{status} == 0 ) {
                die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
            };

        }
        progress(1, $steps);

        # partition external
        $status{status} = "Partition device $external_disk";
        @cmd = [ MANAGER, 'disk','partition', "$external_disk", "raid" ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        progress(2, $steps);

        sleep(5);

        # grab lvs
        @cmd = [ MANAGER, 'lv', 'list' ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $vgs = decode_json($stdout_buf);

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
        progress(3, $steps);

        # Shutting down services
        $status{status} = "Terminating running services";

        foreach ( @services ) {
            my( $service, $init_d ) = @$_;
            next unless -x $init_d;

            $status{status} = "Terminating $service";
            system $init_d, 'stop';
        }

        progress(4, $steps);

        # Backing up the system
        $status{status} = "Backup system";
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

        progress(5, $steps);

        # Unmounting devices
        @cmd = [ MANAGER, 'fstab','is_mounted', "/dev/mapper/$vg-$lv" ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);
        if( ref $err eq 'HASH' and $err->{mounted} ) {
            $status{status} = "Umounting $vg-$lv";
            @cmd = [ MANAGER, 'fstab','umount', "/dev/mapper/$vg-$lv" ];
            run3(@cmd, undef, \$stdout_buf, undef);

            $err = decode_json($stdout_buf);

            if( exists $err->{status} and $err->{status} == 0 ) {
                die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
            };

            # Removal of fstab entry
            $status{status} = "Removing FsTab entry for /dev/mapper/$vg-$lv";
            @cmd = [ MANAGER, 'fstab','remove', "/dev/mapper/$vg-$lv" ];
            run3(@cmd, undef, \$stdout_buf, undef);

            $err = decode_json($stdout_buf);

            if( exists $err->{status} and $err->{status} == 0 ) {
                die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
            };

        } else {
            @cmd = [ MANAGER, 'fstab','is_mounted', "/dev/$vg/$lv" ];
            run3(@cmd, undef, \$stdout_buf, undef);

            $err = decode_json($stdout_buf);
            if( ref $err eq 'HASH' and $err->{mounted} ) {
                $status{status} = "Umounting $vg-$lv";
                @cmd = [ MANAGER, 'fstab','umount', "/dev/$vg/$lv" ];
                run3(@cmd, undef, \$stdout_buf, undef);

                $err = decode_json($stdout_buf);

                if( exists $err->{status} and $err->{status} == 0 ) {
                    die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
                };

                # Removal of fstab entry
                $status{status} = "Removing FsTab entry for /dev/$vg/$lv";
                @cmd = [ MANAGER, 'fstab','remove', "/dev/$vg/$lv" ];
                run3(@cmd, undef, \$stdout_buf, undef);

                $err = decode_json($stdout_buf);

                if( exists $err->{status} and $err->{status} == 0 ) {
                    die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
                };

            }
        }

        progress(6, $steps);

        # Removal of logical volume
        $status{status} = "Removing logical volume $vg-$lv";
        @cmd = [ MANAGER, 'lv','lvremove', "/dev/$vg/$lv" ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        progress(7, $steps);

        # Removing volume group
        $status{status} = "Removing volume group $vg";
        @cmd = [ MANAGER, 'lv','vgremove', "$vg" ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        progress(8, $steps);

        # Revoval of Physical volume devices
        foreach my $partition( @devices ) {
            $status{status} = "Removing physical volume $partition";
            @cmd = [ MANAGER, 'lv','pvremove', "$partition" ];
            my( $stdout_buf, $stderr_buf );
            run3(@cmd, undef, \$stdout_buf, undef);

            $err = decode_json($stdout_buf);

            if( exists $err->{status} and $err->{status} == 0 ) {
                die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
            };
        }

        progress(9, $steps);

        # update internal partition table
        $status{status} = "Updating internal partition type";
        @cmd = [ MANAGER, 'disk','set_partition_type', "$internal", "raid" ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        progress(10, $steps);

        my $nextmd;
        my $partitions;

        # Find the top most device, if any
        $status{status} = "Querying bext MD device name";
        @cmd = [ MANAGER, 'md','get_next_md' ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( ref $err eq 'HASH' and exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        $nextmd = $err->{nextmd};

        $partitions = [ $internal, $external ];

        progress(11, $steps);

        # Creating RAID array
        $status{status} = "Creating RAID array $nextmd";

        # something is fishy down in the diskmanager, do the creation manually for the time beeing
        system(
            'mdadm',
            '--create',
#            '-e', '0.90',
            '--run',
            '--force',
            '--assume-clean',
            $nextmd,
            '--level', $level,
            '--raid-devices', 2,
            '--spare-devices', 0,
            $internal,
            $external
        );

        progress(12, $steps);


		@mdadm_conf = read_file("/etc/mdadm/mdadm.conf");
		@mdadm_conf = grep {!/^ARRAY/} @mdadm_conf;
		push @mdadm_conf, `mdadm --detail --scan`;
		write_file("/etc/mdadm/mdadm.conf", @mdadm_conf);

        progress(13, $steps);

        # TODO
        # uppdatera mdadm.conf

        # Format the RAID array

        $status{status} = "Format RAID array $nextmd";
        @cmd = [ MANAGER, 'disk','format', $nextmd, 'ext3' ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        progress(14, $steps);


        # Setup FsTab
        $status{status} = "Setting up FsTab";
        @cmd = [ MANAGER, 'fstab','add', $nextmd, $mountpath, 'auto', 'defaults', 0, 2 ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };
        progress(15, $steps);

        # Mount
        $status{status} = "Mounting $mountpath";
        @cmd = [ MANAGER, 'fstab','mount', $nextmd ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };
        progress(16, $steps);

        # Restore the previous backup
        $status{status} = "Restoring backup";
        system 'cp', '--archive', '--recursive', glob('/bkup/*'), '/home';
        system 'rm', '-rf', '/bkup';

        progress(17, $steps);

        # Restore default web page
        $status{status} = "Restore the default web page";
        system 'cp', '-a', glob('/usr/share/bubba-backend/default_web/*'), '/home/web';
        system 'chown', 'www-data:users', '/home/web';

        progress(18, $steps);

        # Restarting services
        $status{status} = "Restarting shut down services";


        foreach ( reverse @services ) {
            my( $service, $init_d ) = @$_;
            next unless -x $init_d;
            $status{status} = "Restarting $service";
            system $init_d, 'start';
        }

        progress(19, $steps);
        # workaround for parted when modifying partition table
        system('swapon', '/dev/sda3');

        progress(20, $steps);

        $status{status} = "Conversion to RAID-$level complete";
        $status{done} = 1;
    } catch {
        $status{done} = 1;
        $status{error} = 1;
        $status{status} = "Caught error: $_[0]";
    }
    $is_running = 0;
    $status{overall_action} = 'idle';
    return;

}

sub restore_raid_broken_external {
    my($disk) = @_;
    try {
        reset_status();
        $status{overall_action} = 'restore_raid_broken_external';
        my $steps = 2;
        my $external = "${disk}1";
        my $md = "/dev/md0"; # autodetect?;

        progress(0, $steps);

        my( $stdout_buf, $stderr_buf );
        my @cmd;
        my $err;
        my @devices;
        my $vgs;
        my $cmd_str;

        # workaround for parted when modifying partition table
        system('swapoff', '/dev/sda3');

        # partition external disk
        $status{status} = "Partition external disk";
        @cmd = [ MANAGER, 'disk','partition', "$disk", "raid" ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        progress(1, $steps);
        sleep(5);

        my $nextmd;
        my $partitions;
        $status{status} = "Adding external disk to array";
        @cmd = [ MANAGER, 'md','add', $md, $external ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        progress(2, $steps);

        # workaround for parted when modifying partition table
        system('swapon', '/dev/sda3');

        $status{status} = "The new disk has successfully been added. Synchronizing disks in progress.";
        $status{done} = 1;
    } catch {
        $status{done} = 1;
        $status{error} = 1;
        $status{status} = "Caught error: $_[0]";
    }
    $is_running = 0;
    $status{overall_action} = 'idle';
    return;
}

sub restore_raid_broken_internal {
    my($disk,$part) = @_;
    try {
        reset_status();
        $status{overall_action} = 'restore_raid_broken_internal';


        my $steps = 12;
        progress(0, $steps);

        my $vg = "bubba"; # bubba
        my $lv = "storage"; # storage
        my $internal = "/dev/sda2"; # /dev/sda2
        my $mountpath = "/home"; # /home
        my $md = "/dev/md0"; #autodetect?
        my $external = "${disk}${part}";

        my @services = (
            [ 'cron', '/etc/init.d/cron' ],
            [ 'logitechmediaserver', '/etc/init.d/logitechmediaserver' ],
            [ 'forked-daapd', '/etc/init.d/forked-daapd' ],
            [ 'minidlna', '/etc/init.d/minidlna' ],
            [ 'proftpd', '/etc/init.d/proftpd' ],
            [ 'netatalk', '/etc/init.d/netatalk' ],
            [ 'cups', '/etc/init.d/cupsys' ],
            [ 'ftd', '/etc/init.d/filetransferdaemon' ],
            [ 'dovecot', '/etc/init.d/dovecot' ],
            [ 'fetchmail', '/etc/init.d/fetchmail' ],
            [ 'samba', '/etc/init.d/samba' ],
        );

        my( $stdout_buf, $stderr_buf );
        my @cmd;
        my $err;
        my @devices;
        my $vgs;
        my $cmd_str;

        # workaround for parted when modifying partition table
        system('swapoff', '/dev/sda3');
        # grab lvs
        @cmd = [ MANAGER, 'lv', 'list' ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $vgs = decode_json($stdout_buf);

        foreach my $c_vg( @$vgs ) {
            if( $c_vg->{name} eq $vg ) {
                foreach my $c_lv( @{$c_vg->{lvs}} ) {
                    if( $c_lv->{name} eq $lv ) {
                        @devices = map {m#(/dev/\w+\d)#; $_=$1} @{$c_lv->{devices}};
                    }
                }
            }
        }

        progress(1, $steps);

        # Shutting down services
        $status{status} = "Terminating running services";

        foreach ( @services ) {
            my( $service, $init_d ) = @$_;
            next unless -x $init_d;
            $status{status} = "Terminating $service";
            system $init_d, 'stop';
        }

        progress(2, $steps);

        # Unmounting devices
        @cmd = [ MANAGER, 'fstab','is_mounted', "/dev/mapper/$vg-$lv" ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);
        if( ref $err eq 'HASH' and $err->{mounted} ) {
            $status{status} = "Umounting $vg-$lv";
            @cmd = [ MANAGER, 'fstab','umount', "/dev/mapper/$vg-$lv" ];
            run3(@cmd, undef, \$stdout_buf, undef);

            $err = decode_json($stdout_buf);

            if( exists $err->{status} and $err->{status} == 0 ) {
                die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
            };

            # Removal of fstab entry
            $status{status} = "Removing FsTab entry for /dev/mapper/$vg-$lv";
            @cmd = [ MANAGER, 'fstab','remove', "/dev/mapper/$vg-$lv" ];
            run3(@cmd, undef, \$stdout_buf, undef);

            $err = decode_json($stdout_buf);

            if( exists $err->{status} and $err->{status} == 0 ) {
                die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
            };

        } else {
            @cmd = [ MANAGER, 'fstab','is_mounted', "/dev/$vg/$lv" ];
            run3(@cmd, undef, \$stdout_buf, undef);

            $err = decode_json($stdout_buf);
            if( ref $err eq 'HASH' and $err->{mounted} ) {
                $status{status} = "Umounting $vg-$lv";
                @cmd = [ MANAGER, 'fstab','umount', "/dev/$vg/$lv" ];
                run3(@cmd, undef, \$stdout_buf, undef);

                $err = decode_json($stdout_buf);

                if( exists $err->{status} and $err->{status} == 0 ) {
                    die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
                };

                # Removal of fstab entry
                $status{status} = "Removing FsTab entry for /dev/$vg/$lv";
                @cmd = [ MANAGER, 'fstab','remove', "/dev/$vg/$lv" ];
                run3(@cmd, undef, \$stdout_buf, undef);

                $err = decode_json($stdout_buf);

                if( exists $err->{status} and $err->{status} == 0 ) {
                    die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
                };

            }
        }

        @cmd = [ MANAGER, 'fstab','is_mounted', $external ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);
        if( ref $err eq 'HASH' and $err->{mounted} ) {
            $status{status} = "Umounting $external" ;
            @cmd = [ MANAGER, 'fstab','umount', $external  ];
            run3(@cmd, undef, \$stdout_buf, undef);

            $err = decode_json($stdout_buf);

            if( exists $err->{status} and $err->{status} == 0 ) {
                die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
            };

            # Removal of fstab entry
            $status{status} = "Removing FsTab entry for $external";
            @cmd = [ MANAGER, 'fstab','remove', $external ];
            run3(@cmd, undef, \$stdout_buf, undef);

            $err = decode_json($stdout_buf);

            if( exists $err->{status} and $err->{status} == 0 ) {
                die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
            };

        }

        progress(3, $steps);

        # Removal of logical volume
        $status{status} = "Removing logical volume $vg-$lv";
        @cmd = [ MANAGER, 'lv','lvremove', "/dev/$vg/$lv" ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        progress(4, $steps);

        # Removing volume group
        $status{status} = "Removing volume group $vg";
        @cmd = [ MANAGER, 'lv','vgremove', "$vg" ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        progress(5, $steps);

        # Revoval of Physical volume devices
        foreach my $partition( @devices ) {
            $status{status} = "Removing physical volume $partition";
            @cmd = [ MANAGER, 'lv','pvremove', "$partition" ];
            my( $stdout_buf, $stderr_buf );
            run3(@cmd, undef, \$stdout_buf, undef);

            $err = decode_json($stdout_buf);

            if( exists $err->{status} and $err->{status} == 0 ) {
                die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
            };
        }

        progress(6, $steps);

        # update internal partition table
        $status{status} = "Updating internal partition type";
        @cmd = [ MANAGER, 'disk','set_partition_type', "$internal", "raid" ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        progress(7, $steps);

        # wait for partition update
        sleep 5;

        my $partitions;

        $status{status} = "Assemble degraded array $md";
        @cmd = [ MANAGER, 'md','assemble', $md, $external ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        progress(8, $steps);

        sleep 5;
        $status{status} = "Add internal partition as spare to $md";
        @cmd = [ MANAGER, 'md','add', $md, $internal ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        progress(9, $steps);

        # Setup FsTab
        $status{status} = "Setting up FsTab";
        @cmd = [ MANAGER, 'fstab','add', $md, $mountpath, 'auto', 'defaults', 0, 2 ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        progress(10, $steps);

        # Mount
        $status{status} = "Mounting $mountpath";
        @cmd = [ MANAGER, 'fstab','mount', $md ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        };

        progress(11, $steps);

        # Restarting services
        $status{status} = "Restarting shut down services";


        foreach ( reverse @services ) {
            my( $service, $init_d ) = @$_;
            next unless -x $init_d;
            $status{status} = "Restarting $service";
            system $init_d, 'start';
        }

        progress(12, $steps);

        # workaround for parted when modifying partition table
        system('swapon', '/dev/sda3');

        $status{status} = "$md has been sucessfully restored, full sync will be achieved after a few hours";
        $status{done} = 1;
    } catch {
        $status{done} = 1;
        $status{error} = 1;
        $status{status} = "Caught error: $_[0]";
    }
    $is_running = 0;
    $status{overall_action} = 'idle';
    return;
}

sub format_disk {
    my($disk,$label) = @_;
    try {
        reset_status();
        $status{overall_action} = 'format_disk';
        my $partition = "${disk}1";

        my( $err, $stdin_buf, $stdout_buf, $stderr_buf, $buffer );

        # Disk partition
        $status{status} = "Partition disk $disk";
        my @cmd = [ MANAGER, 'disk', 'partition', $disk, 'raw', $label ];
        run3(@cmd, undef, \$stdout_buf, undef);

        $err = decode_json($stdout_buf);

        if( exists $err->{status} and $err->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        }
        progress(10, 100);

        sleep 5;
        # while the partitions might have been completed, it can take an second or five to sync it
        # so we sleep for 5 secs to make sure it's synced. (this will especially happen for small
        # USB memory sticks)


        # Disk format
        $status{status} = "Format disk $disk";
        my $cmd = [ MANAGER, 'disk', 'format', "${disk}1", 'ext3' ];
        $stderr_buf = 1; # we want to dump errors here
        my $pid = open3($stdin_buf, $stdout_buf, $stderr_buf, @$cmd );
        my $token =  ftok( '/tmp/dmgshm', $pid );
        if( my $sid = shmget( $token, 4096,  S_IRUSR | IPC_CREAT ) ) {
            while( waitpid( $pid, WNOHANG ) != -1 ) {
                shmread($sid, $buffer, 0, 4096);
                substr($buffer, index($buffer, "\0")) = '';
                progress( 10 + $buffer * .8, 100) if $buffer;
                sleep(1);
            }
            shmctl( $sid, IPC_RMID, 0);
        } else {

            waitpid( $pid, 0 );
        }

        my $json_str;
        my $output = <$stdout_buf>;

        $json_str = decode_json($output);

        if( exists $json_str->{status} and $json_str->{status} == 0 ) {
            die(sprintf("Error: %s in command %s", $err->{errmsg}, join( ' ', @{$cmd[0]} )))
        }

        progress(90, 100);

        sleep 5;
        # we'll sleep again before we really sync the new stuff.

        system( MANAGER, 'disk', 'probe', $disk );
        progress(95, 100);


        # Tuning filesystem
        # TODO move to diskmanager
        $status{status} = "Tuning disk $disk";
        $cmd = [ 'tune2fs', '-c', 0, '-i', 0, "${disk}1" ];
        run3 $cmd, \$stdin_buf,  \$stdout_buf, \$stderr_buf;

        progress(100, 100);


        $status{status} = "$disk has been sucessfully formated";
        $status{done} = 1;
    } catch {
        $status{done} = 1;
        $status{error} = 1;
        $status{status} = "Caught error: $_[0]";
    }
    $is_running = 0;
    $status{overall_action} = 'idle';
    return;
}
