#! /usr/bin/perl -w

package Bubba::Apt;
$VERSION = '1.00';

use strict;

use Perl6::Say;
use JSON;
use threads;
use threads::shared;
use base qw(Net::Daemon);
use Parse::DebControl;
use IPC::Run3;
use IPC::Run qw( run new_chunker );
use XML::LibXML;
use Try::Tiny;

use vars qw($exit);
use vars qw($VERSION);

$VERSION = '0.0.1';

my %status : shared;
$status{progress} = 0;
$status{statusMessage} = '';
$status{done} = 0;
$status{logs} = shared_clone({});

my @local_errors : shared;

my $main_status : shared = '';
my $nbr_packages : shared = 0;
my $last_type : shared = '';
my $level : shared = 0;
my $max_level : shared = 0;
my $is_running : shared = 0;
my $is_idle : shared = 0;
my $has_run : shared = 0;

my $from_js;
my $to_js;
if($JSON::VERSION<2){
	$from_js=\&jsonToObj;
	$to_js=\&objToJson;
}else{
	$from_js=\&from_json;
	$to_js=\&to_json;
}

use constant SOCKNAME		=> "/tmp/bubba-apt.socket";
use constant PIDFILE		=> '/tmp/bubba-apt.pid';
use constant LOGFILE		=> '/tmp/bubba-apt.log';

my $WAN : shared						= 'eth0';
my $LAN	: shared 						= 'eth1';

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
	if( ++$is_idle >= 20 ) {
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
			}
			$sock->close();
			return;
		}
		$line =~ s/\s+$//; # Remove CRLF
		my $request;
		eval { $request = $from_js->($line) } || $self->Fatal("Unable to parse \"%s\": %s", $line, $!);
		if(exists $request->{'action'}){
			my $cmd=$request->{'action'};

			if($cmd eq "install_package" && ! $is_running && ! $has_run){
				my $ok=0;
				{
					lock($is_running);
					if(! $is_running && ! $has_run ){
						$is_running = 1;
						$ok = 1;
					}
				}
				if($ok){
					$has_run = 1;
					async {
						unlink LOGFILE;
						INSTALL: {
							last INSTALL unless $self->precheck( $request );
							$self->install_package($request);
							last INSTALL unless $self->postcheck( $request );
						}
						my $logs = shared_clone($self->logfilecheck());
						if( $is_running ) {
							$status{progress} = 100;
							unless( $status{error} ) {
								$status{statusMessage} = $status{fixedMessage} || "Install complete";
							}
							$status{done} = 1;
							$status{logs} = $logs;
							$is_running = 0;
						}

					};
					$sock->say( $to_js->( {response => "install_package"} ) );
				}else{
					$sock->say( $to_js->( {response => "unknown_action"}));
				}
			}elsif($cmd eq "upgrade_packages" && ! $is_running && ! $has_run){
					$self->Debug("1");
				my $ok=0;
				{
					lock($is_running);
					if(! $is_running && ! $has_run){
						$is_running = 1;
						$ok = 1;
					}
				}
				if($ok){
					async {
						$has_run = 1;
						unlink LOGFILE;
						UPGRADE: {
							last UPGRADE unless $self->precheck( $request );
							$self->upgrade_packages($request);
							last UPGRADE unless $self->postcheck( $request );
						}
						my $logs = shared_clone($self->logfilecheck());
						if( $is_running ) {
							$status{progress} = 100;
							unless( $status{error} ) {
								$status{statusMessage} = $status{fixedMessage} || ( $nbr_packages > 0 ? "  $nbr_packages packages upgraded" : "Upgrade complete" );
							}
							$status{done} = 1;
							$status{logs} = $logs;
							$is_running = 0;
						}
					}
					$sock->say( $to_js->( {response => "upgrade_packages"} ) );
				}else{
					$sock->say( $to_js->( {response => "unknown_action"}));
				}
			}elsif($cmd eq "query_progress"){
				$self->query_progress($request);
			} elsif( $cmd eq 'shutdown') {
				$self->Log('notice', "%s server terminating", ref($self));
				$sock->say( $to_js->( {response => "shutdown"} ) );
				$sock->flush();
				$sock->close();
				# cleaning up
				-f $self->{'pidftest@192.168.37.26:ile'} and unlink $self->{'pidfile'};
				-S $self->{'localpath'} and unlink $self->{'localpath'};

				# and terminate ourself
				kill 'INT', $$;
			} else {
				$sock->say( $to_js->( {response => "unknown_action"} ) );
			}
		} else {
			$sock->say( $to_js->( {response => "unknown_command"} ) );
		}
	}
}

sub firewallcheck($) {

	my ($self, $doc) = @_;
	my $failed = 0;

	if( my $context = $doc->findnodes('/iptables-rules/table[@name="filter"]/chain[@name="INPUT"]')->[0] ) {

		my $policy = $context->findvalue('@policy');
		unless( $policy eq "DROP" ) {
			$self->Debug("phailed in DROP");
			$failed = 1;
		}
		{
			my $found = 0;
			foreach my $rule ( $context->findnodes('rule[conditions/match/i = "'.$WAN.'"]') ) {
				next unless $rule->findvalue('count(conditions/*)') == 2;
				next unless $rule->findvalue('count(conditions/state/*)') == 1;
				next unless $rule->findvalue('count(conditions/state/state)') == 1;
				next unless $rule->findvalue('count(actions/*)') == 1;
				next unless $rule->findvalue('count(actions/ACCEPT)') == 1;
				my $state = $rule->findvalue('conditions/state/state');
				if( $state =~ m/RELATED/ && $state =~ m/ESTABLISHED/  ) {
					$found = 1;
					last;
				}
			}
			$failed = 1 unless $found;
		}
		{
			my $found = 0;
			foreach my $rule ( $context->findnodes('rule[conditions/match/i = "'.$LAN.'"]') ) {
				next unless $rule->findvalue('count(conditions/*)') == 1;
				next unless $rule->findvalue('count(actions/*)') == 1;
				next unless $rule->findvalue('count(actions/ACCEPT)') == 1;
				$found = 1;
				last;
			}
			$failed = 1 unless $found;
		}

	} else {
		$failed = 1;
	}

	if( my $context = $doc->findnodes('/iptables-rules/table[@name="nat"]/chain[@name="POSTROUTING"]')->[0] ) {
		{
			my $found = 0;
			foreach my $rule ( $context->findnodes('rule[conditions/match/o = "'.$WAN.'"]') ) {
				next unless $rule->findvalue('count(conditions/*)') == 1;
				next unless $rule->findvalue('count(actions/*)') == 1;
				next unless $rule->findvalue('count(actions/MASQUERADE)') == 1;
				$found = 1;
				last;
			}
			$failed = 1 unless $found;
		}

	} else {
		$failed = 1;
	}

	return !$failed;

}

sub logfilecheck {
	my( $self, $type ) = @_;
	my $result_data = {};

	if( -f LOGFILE ) {
		my $parser = new Parse::DebControl;
		my $data = $parser->parse_file( LOGFILE );
		unless( $data ) {

			lock($is_running);
			$status{statusMessage} = 'Error in parsing logfile';
			$status{error} = 1;
			$status{done} = 1;
			return;
		}
		foreach my $entry ( @$data ) {
			my %cpy = %{$entry};
			my $code = $cpy{'Code'};
			delete $cpy{'Code'};
			push @{$result_data->{$code}}, \%cpy;
		}
	}
	foreach my $entry ( @local_errors ) {
		my %cpy = %{$entry};
		my $code = $cpy{'Code'};
		delete $cpy{'Code'};
		push @{$result_data->{$code}}, \%cpy;
	}

	return $result_data;
}

sub precheck {
	my( $self, $request ) = @_; 
	my $found = 0;
	$status{statusMessage} = "Verifying pre upgrade system integrity.";

	# Step 1: query sound dpkg
	{
		# ^.F is all statuses which is marked failed
		my $output = qx(/usr/bin/dpkg -l  | tail -n +6 | grep -iE ^.F);
		if( $output ) {
			$found = 1;
			push @local_errors, shared_clone({
				Code => 'ERROR',
				Desc => "Failures found in package (dpkg) database, unable to continue with upgrade.",
				Data => $output,
			});
		}
	}
	# Step 2: confirm full functional mysql
	{
		unless( eval { use DBI;DBI->connect("dbi:mysql:mysql", "root", undef, { RaiseError => 1 } ) } ) {
			$found = 1;
			push @local_errors, shared_clone({
				Data => $@,
				Code => 'ERROR',
				Desc => "Failed to access MySQL with default root login, unable to continue with upgrade.",
			});

		}
	}
	# Step 3: confirm full ok Apache2
	{
		my $cmd = '/usr/sbin/apache2ctl configtest 2>&1';
		my $stdout;
		run3( $cmd, undef, \$stdout, undef );
		if( $? >> 8 != 0 ) {
			$found = 1;
			push @local_errors, shared_clone({
				Data => $stdout,
				Code => 'ERROR',
				Desc => "Webserver (apache2) config contains syntax errors.",
			});
		}

	}
	if( $found ) {
		$status{statusMessage} = "System integrity failure.";
		$status{error} = 1;
	}

	return !$found;
}
sub postcheck {
	my( $self, $request ) = @_; 
	$status{statusMessage} = "Verifying post upgrade system integrity.";
	my $found = 0;

	# Step 1: query sound dpkg
	{
		# ^.F is all statuses which is marked failed
		my $output = qx(/usr/bin/dpkg -l  | tail -n +6 | grep -iE ^.F);
		if( $output ) {
			$found = 1;
			push @local_errors, shared_clone({
				Code => 'ERROR',
				Desc => "Failures found in package (dpkg) database.",
				Data => $output,
			});
		}
	}

	# Step 2: confirm full ok Apache2
	# Note: If apache2 has failed to start, no imformation will be sent out
	{
		my $cmd = '/usr/sbin/apache2ctl configtest 2>&1';
		my $stdout;
		run3( $cmd, undef, \$stdout, undef );
		if( $? >> 8 != 0 ) {
			$found = 1;
			push @local_errors, shared_clone({
				Data => $stdout,
				Code => 'ERROR',
				Desc => "Webserver (apache2) config contains syntax errors.",
			});
		}

	}

	# Step 3: check sound firewall
	{
		unless( -f '/etc/network/firewall.conf' ) {
				push @local_errors, shared_clone({
					Code => 'WARN',
					Desc => "Firewall configuration was not found on disk, saving current firewall to disk",
				});
				system("/sbin/iptables-save > /etc/network/firewall.conf");
		}
		my $parser = new XML::LibXML();
		my $doc;
		my $broken_file_firewall = 0;
		my $file_fw = qx{/usr/bin/iptables-xml /etc/network/firewall.conf};
		try {
			$doc = $parser->parse_string( $file_fw );
		} catch {
			push @local_errors, shared_clone({
					Code => 'WARN',
					Desc => "Firewall configuration was corrupt, saving current firewall to disk",
				});			
				system("/sbin/iptables-save > /etc/network/firewall.conf");
				$broken_file_firewall = 1;
		};

		if( $broken_file_firewall || !$self->firewallcheck( $doc ) ) {
			# our firewall config is broken, testing live fw
			my $current_fw = qx{/sbin/iptables-save | /usr/bin/iptables-xml};
			$doc = $parser->parse_string( $current_fw );
			if(  $self->firewallcheck( $doc ) ) {

				push @local_errors, shared_clone({
					Code => 'WARN',
					Desc => "Firewall configuration file is determined to be corrupt. The active firewall is ok and saved to file.",
				});
				# current firewall is ok
				system("/bin/cp /etc/network/firewall.conf /etc/network/firewall.conf-bkup");
				system("/sbin/iptables-save > /etc/network/firewall.conf");
			} else {
				push @local_errors, shared_clone({
					Code => 'WARN',
					Desc => "Running firewall and saved configuration file is determined to be corrupt. Default firewall has been restored.",
				});
				# current running firewall is borked, restore default
				system("/bin/cp /etc/network/firewall.conf /etc/network/firewall.conf-bkup");
				system("/bin/cat /usr/share/bubba-configs/firewall.conf | sed 's/eth1/$LAN/g;s/eth0/$WAN/g' > /etc/network/firewall.conf");
				system("/sbin/iptables-restore /etc/network/firewall.conf");
			}
		} else {
			my $current_fw = qx{/sbin/iptables-save | /usr/bin/iptables-xml};
			$doc = $parser->parse_string( $current_fw );
			unless(  $self->firewallcheck( $doc ) ) { 
				push @local_errors, shared_clone({
					Code => 'WARN',
					Desc => "The running firewall configuration is determined to be corrupt. The saved configuration appears to be valid and will be activated after a reboot.",
				});
			}
		}
	}

	if( $found ) {
		$status{statusMessage} = "System integrity failure.";
		$status{error} = 1;
	}
	
	return !$found;
}

sub _handle_error {
	my ($self, $what) = @_;
	$status{statusMessage} = $what;
	$status{error} = 1;
	$is_running = 0;

}

sub _calculate_progress {
	my ( $self, $current_progress, $gathered, $usage ) = @_;
	$usage = $usage / 100;
	$level = $level > 0 ? $level : 1;

	my $delta = $usage * ( 1 / $max_level ) * $current_progress;

	my $allready_this_round = $usage * ( ( $level -1 ) / $max_level ) * 100;

	my $progress = sprintf( '%.2f', $gathered + $allready_this_round + $delta );

	return $progress;
}

sub _process_line {
	my ( $self, $line, $gathered, $usage ) = @_;
	if( $line =~ /:/ ) {
		my ( $type, $current, $progress, $info ) = split /:/, $line, 4; #/ beats me why this is needed (Eclipse chokes without it)
		return 0 unless $type =~ /opstatus|dlstatus|pmstatus/;

		{
			if( $type ne $last_type and $level < $max_level ) {
				++$level;
				$last_type = $type;
			}
			# Ugly hack :(
			if( $type eq 'pmstatus' ) {
				$level = $max_level;
			}
		}
		
		{
			$status{progress} = $self->_calculate_progress( $progress, $gathered, $usage );
			$status{statusMessage} = "$main_status - $info";
		}
		unless( defined $progress and defined $level and defined $max_level ) {
			return 0;
		}
		return $progress eq '100' && $level == $max_level;
	}
	return 0;
}

sub install_package {
	my ($self, $req) = @_;


	{
		$main_status = 'Install: Updating sources';
		$status{progress} = 0;
		$status{done} = 0;
		$status{statusMessage} = $main_status;
	}
	
	{
		$last_type='';
		$level = 0;
		$max_level = 2;
	}

	open APT, "DEBIAN_FRONTEND=noninteractive /usr/bin/bubba-apt --config-file=/etc/apt/bubba-apt.conf update |";
	while ( <APT> ) {
		last if $self->_process_line( $_, 0, 40 );
	}
	close APT || do {
		$self->_handle_error( "'bubba-apt update' exited $?" );
		return;
	};
	{
		$main_status = 'Install: Installing packages';
		$status{statusMessage} = $main_status;
	}

	{
		$last_type='';
		$level = 0;
		$max_level = 3;
	}
	
	open APT, "DEBIAN_FRONTEND=noninteractive /usr/bin/bubba-apt --config-file=/etc/apt/bubba-apt.conf install $req->{package} |";
	while ( <APT> ) {
		last if $self->_process_line( $_, 40, 60 );
	}
	close APT || do {
		$self->_handle_error( "bubba-apt update install $req->{package}' exited $?" );
		return;
	};
}

sub upgrade_packages {
	$ENV{'DEBIAN_FRONTEND'} = 'noninteractive';

	my ($self, $req) = @_;

	{
		$main_status = 'Upgrade: Updating sources';
		$status{progress} = 0;
		$status{done} = 0;
		$status{statusMessage} = $main_status;
	}

	{
		$last_type='';
		$level = 0;
		$max_level = 2;
	}


	my (@cmd, $outanderr);

	@cmd = qw(/usr/bin/bubba-apt --config-file=/etc/apt/bubba-apt.conf update);

	run \@cmd, '>&', \$outanderr,  '13>', new_chunker(qr(\r|\n)), sub { $self->_process_line(shift, 0, 40) };

	{
		$main_status = 'Upgrade: Querying available upgrades';
		$status{statusMessage} = $main_status;
	}
	# Fake distupgrade -qq really silent, -u list packages to be upgraded, -s no-act
	# Will be empty if no packge to be upgraded
	my @upgrades = qx{DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get -qq -u -s dist-upgrade};
	chomp @upgrades;
	unless( scalar @upgrades ) {
		$status{fixedMessage} = "No upgrades available";
		return;
	} else {
		$nbr_packages = grep { /^Inst/ } @upgrades;
	}

	{
		$main_status = 'Upgrade: Upgrading packages';
		$status{statusMessage} = $main_status;
	}
	
	{
		$last_type='';
		$level = 0;
		$max_level = 3;
	}
	@cmd = qw(/usr/bin/bubba-apt --config-file=/etc/apt/bubba-apt.conf dist-upgrade);
	run \@cmd, '>&', \$outanderr,  '13>', new_chunker(qr(\r|\n)), sub { $self->_process_line(shift, 40, 60) };
}

sub query_progress {
	my ($self,$req)=@_;
	eval { $self->{'socket'}->say( $to_js->( \%status ) ) };
}


1;
