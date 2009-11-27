#!/usr/bin/perl -w

#    thumbnail - creates thumbnails in directories
#    Copyright © 2008 - Carl Fürstenberg <carl@excito.com>
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.


use strict;
use warnings;

use Image::Magick;
use Getopt::Long;
use File::Glob qw(:glob);
use File::stat;
use File::Type;
use File::Basename;
use Pod::Usage;

my $default_width = 100;
my %options = (
	width	=> undef,
	height	=> undef,
	prefix	=> '_thb_',
	force	=> 0,
	strict	=> 0,
	recursive => 1,
	help => 0,
	verbose => 0,
);

my %mime_types = (
	'image/png' => 1,
	'image/x-png' => 1,
	'image/gif' => 1,
	'image/jpeg' => 1,
);

my $ft = new File::Type();

GetOptions(
	\%options,
	'help|?',
	'width:i',
	'height:i',
	'prefix',
	'force!', 
	'strict!',
	'verbose!',
	'recursive!'
) or pod2usage(2);
pod2usage(1) if $options{help};


my $qprefix = quotemeta $options{prefix};
my $geometry = "$default_width\x";

if( defined $options{width} or defined $options{height} ) {
	if( defined $options{width} ) {
		$geometry = "$options{width}";
		if( defined $options{height} ) {
			$geometry .= "x$options{height}";
		}
		if( $options{strict} ) {
			$geometry .= '!';
		}
	}
	elsif( defined $options{height} ) {
		$geometry = "x$options{height}";
	}
} else {
	$options{width} = $default_width;
}

&traverse(@ARGV);

sub traverse {
	foreach my $dir ( @_ ) {
		unless ( -d $dir ) {
			warn "directory $dir doesn't exists; skipping!";
			next;
		}
		print "* Processing directory $dir.\n" if $options{verbose};
		foreach my $file ( bsd_glob( "$dir/*", GLOB_QUOTE ) ) {
			if( -d $file and $options{recursive}) {
				&traverse($file);
				next;
			} elsif ( -d $file ) {
				next;
			}
			my $filename = basename($file);

			my $mime = $ft->checktype_filename( "$dir/$filename" );


			# not an allowed image
			next unless $mime and exists $mime_types{$mime} and  $mime_types{$mime} == 1;

			# thumbnail
			next if $filename =~/^$qprefix/;
			my $thumbname = "$dir/$options{prefix}$filename";
			my $fullname = "$dir/$filename";

			if( -f $thumbname ) {
				my $ts = stat( $thumbname );
				my $is = stat( $fullname );

				if( $is->mtime < $ts->mtime and not $options{force} ) {
					# thumbnail exists and the has been modified after the image in question
					next;
				}
			}


			print "** converting $fullname to $thumbname.\n" if $options{verbose};
			my $im;
			if( $mime eq 'image/jpeg' and defined $options{width} ) {
				$im = new Image::Magick( size => $options{width}*2 );
			} else {
				$im = new Image::Magick();
			}
			$im->Read( "$fullname" );
			$im->Thumbnail(geometry => $geometry);
			$im->Write( "$thumbname" );
		}
	}

}

__END__

=head1 NAME

thumbnail - create thumbnails from pictures in directories

=head1 SYNOPSIS

thumbnail [options] [dir ...]

=head1 OPTIONS

=over 8

=item B<--help>

Print a brief help message and exits.

=item B<--width>

Specifies the targeted width of the resulting thumbnail

=item B<--height>

Specifies the targeted height of the resulting thumbnail

=item B<--prefix>

Specifies the prefix the thumbnails are using, defaults to _thb_

=item B<--strict>

Forces the thumbnail size to be exactly the specified width and height, possibly distoring the aspect ratio.

=item B<--recursive>

Generate thumbnails recusrive, default to true, use --norecursive to disable recursive generation

=item B<--force>

Force generation of thumbnails, even if the thumbnail is newer than the source image

=back

=head1 DESCRIPTION

B<This program> will traverse the given directories, and create thumbnails of images found in there.

=cut

