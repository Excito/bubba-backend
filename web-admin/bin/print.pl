#! /usr/bin/perl -w

use strict;

use constant IOC_NRBITS=>8;
use constant IOC_TYPEBITS=>8;
use constant IOC_SIZEBITS=>13;
use constant IOC_DIRBITS=>3;
use constant IOC_NRSHIFT=>0;
use constant IOC_TYPESHIFT=>(IOC_NRSHIFT+IOC_NRBITS);
use constant IOC_SIZESHIFT=>(IOC_TYPESHIFT+IOC_TYPEBITS);
use constant IOC_DIRSHIFT=>(IOC_SIZESHIFT+IOC_SIZEBITS);

# Direction bits.
use constant IOC_NONE=>0; 
use constant IOC_WRITE=>1;
use constant IOC_READ=>2;

use constant IOCNR_GET_DEVICE_ID=>1;

sub ioc{
	my ($dir,$type,$nr,$size)=@_;
	return( (($dir)  << IOC_DIRSHIFT)|
			(($type) << IOC_TYPESHIFT) | 
			(($nr)   << IOC_NRSHIFT) | 
			(($size) << IOC_SIZESHIFT));
}

sub ioc_get_device_id{
		my $len=shift;

		return ioc(IOC_READ, 80, IOCNR_GET_DEVICE_ID,$len);
}

# Private function to scan system for attached printers
#
# Args   : None
#
# Outputs: Nothing 
#
# Return : List of hashes with printerconfigs
#
sub retreive_attached_printers{
	my @res;
	for(0..15){
			
		open(DEV, "/dev/usb/lp$_") or next;
		my $res="\0"x1024;
		ioctl(DEV, ioc_get_device_id(1024),$res);
		close(DEV);
	
		$res=substr($res,2);
		my @val=split(";",$res);
		
		my %cfg;
		my $key;
		foreach $key (@val){
			my ($k,$v)=split(":",$key);
			if($k and $v){
					#print "Key: $k Value: $v\n";
				if( ($k eq "MFG")||($k eq "MANUFACTURER")){
					$cfg{"mfg"}=$v;
				}elsif( ($k eq "DES") || ($k eq "DESCRIPTION")){
					$cfg{"desc"}=$v;
				}elsif( ($k eq "MDL") || ($k eq "MODEL")){
					$cfg{"model"}=$v;
				}elsif( ($k eq "SERN") || ($k eq "SERIALNUMBER") || ($k eq "SN")){
					$cfg{"serial"}=$v;
				}
			}
			
				
		}
		push(@res,\%cfg);
	}
	return @res;
}

# Get installed printers
#
# Args   : None
#
# Outputs: printers and status/config on the format
#          printername configkey "configvalue"
#
# Return : None   
#
sub get_installed_printers{
        open FIL, "/etc/cups/printers.conf" or die "Couldnt open cups config file";
        my @data=<FIL>;
        close FIL;
        chomp(@data);

        my $tagstatus=0;
        my $line;
        my $name;
        foreach $line (@data){
                if($line=~ /^#/){
                                next;
                }
                if($line=~ /\<.*Printer (.*)\>/){
                                $name=$1;
                                $tagstatus=1;
                                next;
                }
                if($line=~ /\<\/Printer\>/){
                                $tagstatus=0;
                                next;
                }
                if($tagstatus){
                                my ($key,@value)=split(/ /,$line);
                                my $value=join(" ",@value);
                                print "$name $key \"$value\"\n";
                }
        }
        return 0;
}


# Get attached printers
#
# Args   : None
#
# Outputs: printers one line per printer
#          Syntax url "Descriptive text" 
#
# Return : None
#
sub get_attached_printers{
	my @printers=retreive_attached_printers();
	
	my $printer;
	foreach $printer (@printers){
		my $mm;
		my $desc;
		if(exists ${$printer}{"desc"}){
		   if( ${$printer}{"desc"}=~ /^Hewlett-Packard /){
		      $mm=${$printer}{"desc"};
		      $desc=$mm;
            $mm=~s/^Hewlett-Packard /HP\//;		      
		   }else{
		      $desc=${$printer}{"desc"};
		      $mm=${$printer}{"desc"};
		      $mm=~s/^(\S+) /$1\//;
		   }
		}elsif((exists ${$printer}{"mfg"})&&(exists ${$printer}{"model"})){
		   $mm=${$printer}{"mfg"}."/".${$printer}{"model"};
		   $desc=${$printer}{"mfg"}." ".${$printer}{"model"};
		}else{
		   $mm="Unknown";
		   $desc=$mm;
		}
      
      if($mm ne "Unknown"){
         $mm=~s/ /%20/g;
      }
      if(exists ${$printer}{"serial"}){
         $mm.="?serial=".${$printer}{"serial"};
      }
		print "usb://$mm \"$desc\"\n";
	}
	return 0;
}

# Add printer
#
# Args   : name - Symbolic name of printer
#          url  - url to printer
#          info - Textual info on printer
#          loc  - Location 
#
# Outputs: Nothing 
#
# Return : Status of operation
#
sub add_printer{
   my ($name,$url,$info,$loc)=@_;
   print "Add printer $name at $url\n";
   
   return system("/usr/sbin/lpadmin -p \"$name\" -v $url -D \"$info\" -L \"$loc\" -o raw -E");
}

# Delete printer
#
# Args   : name - Symbolic name of printer
#
# Outputs: Nothing 
#
# Return : Status of operation
#
sub delete_printer{
   my ($name)=@_;
   print "Delete printer $name\n";
   
   return system("/usr/sbin/lpadmin -x $name");
}

# Set default printer
#
# Args   : name - Symbolic name of printer
#
# Outputs: Nothing 
#
# Return : Status of operation
#
sub set_default_printer{
   my ($name)=@_;
   print "Set default printer $name\n";
   
   return system("/usr/sbin/lpadmin -d \"$name\"");
}

# Get default printer
#
# Args   : none
#
# Outputs: Name of default printer 
#
# Return : Status of operation
#
sub get_default_printer{
   print "Get default printer\n";
   my $defp=`/usr/bin/lpstat -d`;
   print split /:/,$defp ;
   print "\n";
   return 0;
}

# Enable printer
#
# Args   : name - Symbolic name of printer
#
# Outputs: Nothing 
#
# Return : Status of operation
#
sub enable_printer{
   my ($name)=@_;
   return system("/usr/bin/cupsenable \"$name\"");
}

# Disable printer
#
# Args   : name - Symbolic name of printer
#
# Outputs: Nothing 
#
# Return : Status of operation
#
sub disable_printer{
   my ($name)=@_;
   return system("/usr/bin/cupsdisable \"$name\"");
}


if ((scalar(@ARGV))==0) {
   die "Not enough arguments";
}

my $args=scalar @ARGV;
my $cmd=$ARGV[0];

if ( $cmd eq "get_installed_printers" ){

   if ($args==1) {
      get_installed_printers()==0 or exit 1;
   }else{
      print "Invalid parametercount\n";
      exit 1;
   }

}elsif ( $cmd eq "get_attached_printers" ){

   if ($args==1) {
      get_attached_printers()==0 or exit 1;
   }else{
      print "Invalid parametercount\n";
      exit 1;
   }

}elsif ( $cmd eq "add_printer" ){

   if ($args==5) {
      add_printer($ARGV[1],$ARGV[2],$ARGV[3],$ARGV[4])==0 or exit 1;
   }else{
      print "Invalid parametercount\n";
      exit 1;
   }

}elsif ( $cmd eq "delete_printer" ){

   if ($args==2) {
      delete_printer($ARGV[1])==0 or exit 1;
   }else{
      print "Invalid parametercount\n";
      exit 1;
   }

}elsif ( $cmd eq "set_default_printer" ){

   if ($args==2) {
      set_default_printer($ARGV[1])==0 or exit 1;
   }else{
      print "Invalid parametercount\n";
      exit 1;
   }

}elsif ( $cmd eq "get_default_printer" ){

   if ($args==1) {
      get_default_printer()==0 or exit 1;
   }else{
      print "Invalid parametercount\n";
      exit 1;
   }

}elsif ( $cmd eq "enable_printer" ){

   if ($args==2) {
      enable_printer($ARGV[1])==0 or exit 1;
   }else{
      print "Invalid parametercount\n";
      exit 1;
   }

}elsif ( $cmd eq "disable_printer" ){

   if ($args==2) {
      disable_printer($ARGV[1])==0 or exit 1;
   }else{
      print "Invalid parametercount\n";
      exit 1;
   }

}else {
   print "Unknown command\n";
   exit 1;
}


#my_dump(get_attached_printers());
#get_installed_printers();
