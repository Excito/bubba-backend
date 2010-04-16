#! /usr/bin/perl -w
package Bubba::Hotfix::Status;

use constant {
        FOUND                     => 0x0001, # Hotfix was found
        BLOCK                     => 0x0002, # Upgrade must be blocked
        SCRIPTS                   => 0x0004, # hotfix includes executeable scripts
        FILES                     => 0x0008, # hotfix includes files to be installed

        # Error states
        MAC_KEY_MISSMATCH         => 0x4000, # mac id and key not matched
        FAILED_REQUEST            => 0x8000, # request has failed
};

1;

package Bubba::Hotfix;

use strict;

use Perl6::Say;
use JSON;
use threads;
use threads::shared;
use File::Slurp;
use base qw(Net::Daemon);
use IPC::Run3;
use MIME::Base64;
require File::Temp;
require LWP::UserAgent;

use vars qw($exit);
use vars qw($VERSION);

$VERSION = '0.0.1';

my %status : shared;
$status{statusMessage} = 'Checking for hotfixes';
$status{done} = 0;
$status{stop} = 0;

my $is_running : shared = 0;
my $is_idle : shared = 0;


use constant SOCKNAME		=> "/tmp/bubba-hotfix.socket";
use constant PIDFILE		=> '/tmp/bubba-hotfix.pid';
use constant BUBBAKEY		=> "/etc/network/bubbakey";
use constant HOTFIX_URL		=> "https://hotfix.excito.org";

my $WAN						= 'eth0';
my $LAN						= 'eth1';

sub new($$;$) {
	my($class, $attr, $args) = @_;
	$LAN = `bubba-networkmanager-cli getlanif`;
	chomp $LAN;
	my($self) = $class->SUPER::new($attr, $args);
	$self;
}

sub Loop($) {
	my ($self) = @_;
	if( $is_running ) {
		$self->Debug("Loop: is still running");
		$is_idle = 0;
		return;
	}
	if( ++$is_idle >= 2 ) {
		$self->Log('notice', "Timeout: %s server terminating", ref($self));
		# cleaning up
		-f $self->{'pidfile'} and unlink $self->{'pidfile'};
		-S $self->{'localpath'} and unlink $self->{'localpath'};
		kill 'INT', $$;
	}
}

sub Run($) {
	my ($self) = @_;
	my ($line,$sock);
	$sock = $self->{'socket'};
	while(1) {

		if (!defined($line = $sock->getline())) {
			if ($sock->error()) {
				$self->Error("Client connection error %s",
					$sock->error());
			}use constant Hotfix => {
        FOUND                     => 0x0001, # Hotfix was found
        BLOCK                     => 0x0002, # Upgrade must be blocked
        SCRIPTS                   => 0x0004, # hotfix includes executeable scripts
        FILES                     => 0x0008, # hotfix includes files to be installed

        # Error states
        MAC_KEY_MISSMATCH         => 0x4000, # mac id and key not matched
        FAILED_REQUEST            => 0x8000, # request has failed
};

			$sock->close();
			return;
		}
		$line =~ s/\s+$//; # Remove CRLF
		my $request;
		eval { $request = from_json($line) } || $self->Fatal("Unable to parse \"%s\": %s", $line, $!);
		if(exists $request->{'action'}){
			my $cmd=$request->{'action'};

			if($cmd eq "run" and not $is_running){
				my $ok=0;
				{
					lock($is_running);
					if(not $is_running){
						$is_running = 1;
						$ok = 1;
					}
				}
				if($ok){
					async {
						my %args;
						{
							my @ifconfig  = qx(/sbin/ifconfig $WAN);
							my @macs = map { /HWaddr (.*?)\s*\n/; $_ = $1 if $1 } grep( /HWaddr/, @ifconfig);
							$args{mac_1} = $macs[0] if scalar @macs;
							my @ips = map { /inet addr:(\d+\.\d+\.\d+\.\d+)/; $_ = $1 if $1 } grep( /inet addr/, @ifconfig);
							$args{ip_1} = $ips[0] if scalar @ips;
						}

						{
							my @ifconfig  = qx(/sbin/ifconfig $LAN);
							my @macs = map { /HWaddr (.*?)\s*\n/; $_ = $1 if $1 } grep( /HWaddr/, @ifconfig);
							$args{mac_2} = $macs[0] if scalar @macs;
							my @ips = map { /inet addr:(\d+\.\d+\.\d+\.\d+)/; $_ = $1 if $1 } grep( /inet addr/, @ifconfig);
							$args{ip_2} = $ips[0] if scalar @ips;
						}

						{
							my %meminfo = map { /(.*?)\s*:\s*(.*)\s*/ and ($1 => $2) } @{[read_file( "/proc/meminfo" )]};
							my $ram;
							if( defined $meminfo{MemTotal} ) {
								$ram = $meminfo{MemTotal};
							}
							chomp $ram;
							$args{ram} = $ram;
						}

						{
							my %cpuinfo = map { /(.*?)\s*:\s*(.*)\s*/ and ($1 => $2) } @{[read_file( "/proc/cpuinfo" )]};
							my $cpu;
							if( defined $cpuinfo{model} ) {
								$cpu = $cpuinfo{model};
							}
							chomp $cpu;
							$args{cpu} = $cpu;
						}

						{
							my %cmdline = map { /(.*?)=(.*)/ and ($1 => $2) } split(/ /, read_file( "/proc/cmdline" ));
							my $key;
							if( defined $cmdline{key} && $cmdline{key} ne '' ) {
								$key = $cmdline{key};
							} else {
								$key = read_file( BUBBAKEY );
							}
							chomp $key;
							$args{secret_key} = $key;

							my $serial;
							if( defined $cmdline{serial} ) {
								$serial = $cmdline{serial};
							}

							chomp $serial;
							$args{serial} = $serial;
						}

						{
							my @dpkg = qx{dpkg -l bubba-* squeezecenter filetransferdaemon | tail -n +6};
							@dpkg = map { /^(\w{2,3})\s+(\S+)\s+(\S+)/; [$1,$2,$3] } @dpkg;
							$args{dpkg} = \@dpkg;
						}

						{
							if( -f '/tmp/bubba-apt.log' ) {
								$args{bubba_apt_log} =  read_file( '/tmp/bubba-apt.log' );
							}
						}

						{
							if( -f '/var/lib/bubba/hotfix.date' ) {
								$args{last_date} =  read_file( '/var/lib/bubba/hotfix.date' );
							}
						}

						{
							if( -f '/etc/bubba.version' ) {
								$args{version} = read_file( '/etc/bubba.version' );
							} else {
								$args{version} = 0;
							}
						}

						{
							my $kernel = qx{uname -r};
							chomp $kernel;
							$args{kernel} = $kernel;
						}

						{
							my $disks = from_json(qx{/usr/sbin/diskmanager disk list});
							foreach my $disk( @$disks ) {
								if( $disk->{dev} eq '/dev/sda' ) {
									$args{hd_model} = $disk->{model};
									foreach my $part ( @{$disk->{partitions}} ) {
										if( $part->{dev} eq '/dev/sda2' ) {
											$args{hd_usage} = $part->{usage};
											last;
										}
									}
									last;
								}
							}

						}

						{
							my ($dev, $size, $used, $avail, $percent, $mount) = split /\s+/, qx{df --portability -B 1024 / | tail -n +2};
							$args{root_avail} = int($avail);
						}

						my $ua = new LWP::UserAgent;
						$ua->timeout(10);
						my $response = $ua->post( HOTFIX_URL, { data => to_json(\%args) } );
						my ( $stdin, $stdout );
						$stdin = $response->decoded_content;
						run3( ['gpg', '--decrypt', '--batch', '--quiet', '--no-tty' ], \$stdin, \$stdout, \undef );
						if( $? >> 8 == 0 ) {
							my $data = from_json( $stdout );
							my $stat = $data->{status};
							if( $stat & Bubba::Hotfix::Status::FOUND ) {

								if( $stat & Bubba::Hotfix::Status::FILES ) {
									foreach my $file( @{$data->{files}} ) {
										$self->Log( 'info', "Installing file $file->{filename} to $file->{destination}"  );
										$status{statusMessage} = "Installing file $file->{filename}";
										my $mod = defined $file->{mod} ? $file->{mod} : 0644;
										my $uid = defined $file->{uid} ? $file->{uid} : 1;
										my $gid = defined $file->{gid} ? $file->{gid} : 1;
										open FH, '>', $file->{destination};
										binmode(FH);
										print FH  decode_base64($file->{data});
										close FH;
										chown $uid, $gid, $file->{destination};
										chmod $mod, $file->{destination};
									}
								}

								if( $stat & Bubba::Hotfix::Status::SCRIPTS ) {
									foreach my $script( @{$data->{scripts}} ) {
										$self->Log( 'info', "Applying script $script->{scriptname}" );
										$status{statusMessage} = "Applying script $script->{scriptname}";
										my $filename = qx{tempfile --mode 0700};
										chomp $filename;
										open FH, '>', $filename;
										binmode(FH);
										print FH  decode_base64($script->{data});
										close FH;
										my $ret = system( $filename );
										unless( $ret == 0 ) {
											$self->Error("$script->{scriptname} failed: $?");
										}
										unlink $filename;
									}

								}
								# do apply hotfixes here
								if( $stat & Bubba::Hotfix::Status::BLOCK ) {
									$status{statusMessage} = "Automatic updates has been blocked by serverside.";
									$status{stop} = 1;
								} else {
									$status{statusMessage} = "Hotfixes applied, proceeding with upgrade";
								}
							} elsif( $stat & Bubba::Hotfix::Status::BLOCK ) {
								$status{statusMessage} = "Automatic updates has been blocked by serverside.";
								$status{stop} = 1;

							} elsif( $stat & Bubba::Hotfix::Status::FAILED_REQUEST ) {
								if( $stat & Bubba::Hotfix::Status::MAC_KEY_MISSMATCH ) {
									$status{statusMessage} = "MAC address and system key does not match, or is not registered, please contact support";
									$status{stop} = 1;
								} else {
									$status{statusMessage} = "Server indicated failure, but did not specify reason. Normal upgrade will continue.";
								}
							} else {
								$status{statusMessage} = "No hotfixes available, proceeding with upgrade.";
							}
							$status{data} = shared_clone( $data );
						} else {
							$status{statusMessage} = "Failed to verify response from server, proceeding with upgrade";
						}
						$self->Log( 'info', "Status: $status{statusMessage}" );
						$is_running = 0;
						$status{done} = 1;


					};
					$sock->say( to_json( {response => "ok"} ) );
				}else{
					$sock->say( to_json( {response => "not_ok"} ) );
				}
			} elsif($cmd eq "query_progress"){
				eval { $self->{'socket'}->say( to_json( \%status ) ) };
			} else {
				$sock->say( to_json( {response => "unknown_action"} ) );
			}
		} else {
			$sock->say( to_json( {response => "unknown_command"} ) );
		}
	}
}

1;
