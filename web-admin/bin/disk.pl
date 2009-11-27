#! /usr/bin/perl -w

use strict;

sub trim{
	my $string=shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}

sub file{
	my $file=shift;
	open FIL, "$file" or return "";
	my @cnt=<FIL>;
	close FIL;
	chomp(@cnt);
	return join("\n",@cnt);
}

sub get_pvs{
	my $vg=shift;
	my @pvs=`pvdisplay -c 2> /dev/null`;
	my @res;
	foreach my $pv(@pvs){
		my @vals=split(/:/,$pv);
		if($vals[1] && $vals[1] eq $vg){
			my %val=(
				"dev",trim($vals[0]),
				"group",$vals[1],
				"size",$vals[2],
				"volno",$vals[3],
				"volstat",$vals[4],
				"volall",$vals[5],
				"nologval",$vals[6],
				"extsize",$vals[7],
				"exttot",$vals[8],
				"extfree",$vals[9],
				"extalloc",$vals[10],
				"type","physicalvolume"
			);
			push(@res,\%val);
		}
	}
	return \@res;
}

sub get_vgs{
	my @vgs=`vgdisplay -c 2> /dev/null`;
	my @res;

	foreach my $vg (@vgs){
		my @vals=split(/:/,$vg);
		my %val=(
			"name",trim($vals[0]),
			"access",$vals[1],
			"status",$vals[2],
			"intvolgroup",$vals[3],
			"maxlogvol",$vals[4],
			"curlogvol",$vals[5],
			"opencount",$vals[6],
			"maxlogsize",$vals[7],
			"maxphysvol",$vals[8],
			"curphysvol",$vals[9],
			"actphysvol",$vals[10],
			"size",$vals[11],
			"extsize",$vals[12],
			"totexts",$vals[13],
			"allocexts",$vals[14],
			"freeexts",$vals[15],
			"uuid",$vals[16],
			"type","volumegroup"
		);
		$val{"pvs"}=get_pvs($val{"name"});
		push(@res,\%val);
	}
	return \@res;
}

sub get_mdslaves{
	my $path=shift;
	my @res;

	my @slaves=glob("$path/slaves/*");
	foreach my $slave (@slaves){
		my %val;
		my @el=split("/",$slave);
		my $dev=pop(@el);
		$val{"dev"}="/dev/$dev";
		$val{"size"}=file("$slave/size");
		$val{"type"}="arrayslave";
		push(@res,\%val);
	}
	return \@res;
}

sub get_mds{
	my @res;
	my @mds=glob("/sys/block/md?");
	
	foreach my $md (@mds){
		my %val;
		my @el=split("/",$md);
		my $dev=pop(@el);
		$val{"dev"}="/dev/$dev";
		$val{"size"}=file("$md/size");
		$val{"type"}="array";
		$val{"level"}=file("$md/md/level");
		$val{"state"}=file("$md/md/array_state");
		$val{"chunksize"}=file("$md/md/chunk_size");
		$val{"disks"}=file("$md/md/raid_disks");
		$val{"slaves"}=get_mdslaves($md);

		push(@res,\%val);
	}
	return \@res;
}

sub get_partitions{
	my $diskpath=shift;
	my @parts=glob("$diskpath/sd??");
	my $res=[];
	foreach my $part (@parts){
		my $val={};
		my @el=split("/",$part);
		my $dev=pop(@el);
		$val->{"dev"}="/dev/$dev";
		$val->{"size"}=file("$part/size");
		$val->{"type"}="partition";
		$val->{"usage"}="unused";
		push(@{$res},$val);
	}
	return $res;
}

sub get_disks{

	my @disks=glob "/sys/block/sd?";
	my @res;
	foreach my $disk(@disks){
		my $val={};
		my @el=split("/",$disk);
		my $dev=pop(@el);
		$val->{"type"}="disk";
		$val->{"usage"}="unused";
		$val->{"dev"}="/dev/$dev";
		$val->{"model"}=trim(file("/sys/block/$dev/device/model"));
		$val->{"vendor"}=trim(file("/sys/block/$dev/device/vendor"));
		$val->{"partitions"}=get_partitions($disk);
		push(@res,$val);
	}
	return @res;

}

sub set_disk_usage{
	my ($disks,$dev,$usage)=@_;

	foreach my $disk (@{$disks}){
		if($$disk{"dev"} eq $dev){
			$$disk{"usage"}=$usage;
		}else{
			if(scalar $$disk{"partitions"}>0){
				foreach my $part (@{$$disk{"partitions"}}){
					if( $$part{"dev"} eq $dev){
						$$part{"usage"}=$usage;
						$$disk{"usage"}="inuse";
					}
				}
			}
		}
	}

}

sub get_mount_path{
	my $mounts=shift;
	my $dev=shift;
	foreach my $mount (@{$mounts}){
		if($$mount{"dev"} eq $dev){
			return $$mount{"path"};
		}
	}
	return "";
}

sub get_mounts{
	my @res;
	open FIL,"/etc/mtab" or die "Could not open file";
	while(<FIL>){
		chomp;
		next if($_!~/^\/dev/);
		if($_=~ m/^(\/dev\/\S*)\s(\S*)\s/){
			my $val={};
			$val->{"dev"}=$1;
			$val->{"path"}=$2;
			push(@res,$val);
		}
		
	}
	close(FIL);
	return \@res;
}

# Vi vill hitta partitioner som inte är monterade (För usecase #1)
# Vi vill hitta diskar utan partitioner som inte är monterade (Usecase #1)
# Vi vill hitta diskar som inte ingår i ngn lvm,array eller är monterade
sub find_unusage{
	my $disks=shift;
	my $mounts=shift;
	my $arrs=shift;
	my $lvms=shift;

	foreach my $mount (@{$mounts}){
		set_disk_usage($disks,$$mount{"dev"},"mounted");
	}

	foreach my $arr (@{$arrs}){
		my @slaves=@{$$arr{"slaves"}};
		foreach my $slave(@slaves){
			set_disk_usage($disks,$$slave{"dev"},"array");
		}
	}

	foreach my $lvm (@{$lvms}){
		my @pvs=@{$$lvm{"pvs"}};
		foreach my $pv (@pvs){
			set_disk_usage($disks,$$pv{"dev"},"pv");
		}
	}
	
}

sub get_devices{
	my $disks=shift;
	my $res=[];

	foreach my $disk (@{$disks}){
		my $parts=scalar @{$$disk{"partitions"}};
		if($$disk{"usage"} eq "unused" && $parts==0){
			my $val={};
			$val->{"dev"}=$$disk{"dev"};
			$val->{"usage"}=$$disk{"usage"};
			$val->{"model"}=$$disk{"model"};
			$val->{"vendor"}=$$disk{"vendor"};
			push(@{$res},$val);
		}else{
			foreach my $part (@{$$disk{"partitions"}}){
				my $val={};
				$val->{"dev"}=$$part{"dev"};
				$val->{"usage"}=$$part{"usage"};
				$val->{"model"}=$$disk{"model"};
				$val->{"vendor"}=$$disk{"vendor"};
				push(@{$res},$val);
			}
		}
	}
	return $res;
}

sub check_mountpath{
	my $path=shift;
	my $res=0;
	my $mounts=get_mounts();

	foreach my $mount (@{$mounts}){
		if($$mount{"path"} eq $path){
			$res=1;
		}
	}

	print "$res\n";
	return 0;
}
sub list_devices{

	my @mounts=get_mounts();
	my @mds=get_mds();
	my @disks=get_disks();
	my @lvm=get_vgs();

	find_unusage(\@disks,@mounts,@mds,@lvm);
	my $devs=get_devices(\@disks);

	foreach my $dev (@{$devs}){
		print "$$dev{'dev'}:";
		print "$$dev{'usage'}:";
		if($$dev{"usage"} eq "mounted"){
			print get_mount_path(@mounts,$$dev{"dev"}).":";
		}else{
			print ":";
		}	
		print "$$dev{'model'}:";
		print "$$dev{'vendor'}\n";
	}

}

sub user_mount{
	my ($device,$mountpoint,$fstype)=@_;

	$device or return -1;
	$mountpoint or return -1;
	if($fstype && ($fstype!="")){
		$fstype="-t $fstype";
	}else{
		$fstype or $fstype="";
	}
	my $gid=getgrnam("users");
	if(system("/bin/mount $fstype -ogid=$gid,umask=0 $device $mountpoint 2>/dev/null")!=0){
		# NO win-fs do ordinary mount
		return system("/bin/mount $fstype $device $mountpoint");
	}
	return 0;
}

sub user_umount{
	my $mountpoint=shift;

	return system("/bin/umount $mountpoint");
}

# Hash with all commands
# Key 	- name to use when called
# value	- function to be called and number of arguments
my %commands=(
	"list_devices"		=> [\&list_devices,0],
	"user_mount"		=> [\&user_mount, 3],
	"user_umount"		=> [\&user_umount, 1],
	"check_mountpath"	=> [\&check_mountpath,1],
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
		die "Invalid parametercount";
	}
}



