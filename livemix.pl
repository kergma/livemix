#!/usr/bin/perl
q\
Livemix, an automated live multitrack sound recordings downmixer
Copyright (c) 2013 by Sergey Pushkin <pushkinsv@gmail.com>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>
\;

use strict;
use File::Find;
use File::Basename;
use File::stat;
use List::Util qw/min max/;
use Cwd 'realpath';
use Getopt::Long;
use Date::Format;
use Date::Parse;

print q\Livemix Copyright (C) 2013 Sergey Pushkin
This program comes with ABSOLUTELY NO WARRANTY.
This is free software, and you are welcome to redistribute it
under certain conditions; see COPYING file for details.

\;

my ($wav,$mp3,$start_from,$silence_thr,$sox,$format,$lame,$help);
my @effects;
GetOptions (
	'wav'=>\$wav,
	'mp3'=>\$mp3,
	'start-from=s'=>\$start_from,
	'silence-threshold=s'=>\$silence_thr,
	'effect=s'=>\@effects,
	'sox=s'=>\$sox,
	'format=s'=>\$format,
	'lame=s'=>\$lame,
	'h|help'=>\$help
);
if ($help)
{
	print "$0 [-h|--help] [--wav] [--mp3] [--format=output format] [--start-from=datetime] [--silence-threshold=number] [--effect=[!]regex,effect,args] [--sox=path args] [--lame=path args] [source dir] [target dir]\n";
	exit;
};

my $source=shift;
my $target=shift;

$source='.' unless $source;
$source =~ s'\\'/'g;
$source =~ s'/$''g;
print "source dir $source\n";

$target=dirname($0) unless $target;
$target =~ s'\\'/'g;
$target =~ s'/$''g;
print "target dir $target\n";

my $home=dirname(realpath($0));
$ENV{PATH}="$home;$ENV{PATH}" if $ENV{OS} =~ /windows/i;
print "home dir $home\n";

$mp3=1 unless $mp3 or $wav;

unless ($start_from)
{
	my @files=glob("$target/*.mp3") if $mp3;
	push @files,glob("$target/*.wav") if $wav;
	$start_from=max map {str2time(basename($_,'.wav','.mp3'))} @files;
} 
else
{
	$start_from=str2time($start_from);
};

print "starting from ",time2str('%Y-%m-%d %H:%M:%S',$start_from),"\n";
$silence_thr//=0.02;
printf "silence threshold %f\n",$silence_thr;

@effects=(',compand 0.2,1 -70,-60,-30,-30,-20,-10,-20,-5,-50 -5 -90 0.2') unless @effects;
print "effects\n",join("\n",@effects),"\n";

$sox||='sox --combine=mix --norm=-3';
my @sox=($1,split /\s+/,$3) if $sox=~/^(.*sox(\.exe|))\s*(.*)$/i;

$lame||='lame --quiet --abr 160';
my @lame=($1,split /\s+/,$3) if $lame=~/^(.*lame(\.exe|))\s*(.*)$/i;

$format||='--bits=16 --rate=44100';
my @format=split /\s+/,$format;

my $formats='wav au';
my $soxhelp=`$sox[0] --help`;
$formats=$1 if $soxhelp =~ /AUDIO FILE FORMATS: (.*?)$/smi;

$formats=join('|',split / /,$formats);

my (%files, $total_files, $files_read);
find( {wanted => sub {
	my $filename=basename($File::Find::name);
	my $size=-s $File::Find::name;
	my $mtime=stat($File::Find::name)->[9];
	++$total_files and push @{$files{$File::Find::dir}{$size}},
		{name=>$filename, size=>$size, mtime=>$mtime}
		if $filename =~ /\.($formats)/i and $mtime>$start_from;
}, no_chdir => 1}, $source);

my %sessions;
foreach my $d (keys %files)
{
	foreach my $s (keys %{$files{$d}})
	{
		my $f=$files{$d}{$s};
		$total_files-- xor next if scalar(@$f)<2;

		my $S={dir=>$d,files=>[@$f],endtime=>min(map {$_->{mtime}} @$f)};
		$sessions{"$d-$s"}=$S;
		foreach my $f (@{$files{$d}{$s}})
		{
			printf "reading $f->{name} (%d left)\n",$total_files-++$files_read;
			my $stat=`$sox[0] "$d/$f->{name}" -n stat 2>&1`;
			my ($max,$min);
			$max=$1 if $stat=~/Maximum amplitude:\s+(\S+)/;
			$min=$1 if $stat=~/Minimum amplitude:\s+(\S+)/;
			if ($max-$min<$silence_thr)
			{
				print "skipping $f->{name} due to silence detected\n";
				@{$S->{files}}=grep {$_!=$f} @{$S->{files}};
				if (scalar(@{$S->{files}})<2)
				{
					delete $sessions{"$d-$s"};
					last;
				};
				next;
			};
			my $duration=$1 if $stat=~/Length \(seconds\):\s+(\d+)/smi;
			$duration+=0;
			if ($sessions{"$d-$s"}->{endtime}-$duration <= $start_from)
			{
				print "skipping ",time2str('%Y%m%d-%H%M%S',$sessions{"$d-$s"}->{endtime}),"\n";
				delete $sessions{"$d-$s"};
				last;
			};
			my $volume=$1 if $stat=~/Volume adjustment:\s+([\d\.]*)/smi;
			$sessions{"$d-$s"}->{duration}//=$duration;
			$f->{volume}=$volume||1;
		};
		
	};
};

my $sessions_mixed;
foreach my $s (sort {$a->{endtime}-$a->{duration}<=>$b->{endtime}-$b->{duration}} values %sessions)
{
	$s->{name}=time2str('%Y%m%d-%H%M%S',$s->{endtime}-$s->{duration});
	foreach my $f (@{$s->{files}})
	{
		$f->{tempname}="$s->{dir}/$f->{name}";
		foreach my $e (@effects)
		{
			$e=~/^(.*?)[, ](.*?)(|[, ](.*))$/;
			my ($regex,$effect,$args)=($1,$2,$4);
			next unless $effect;
			my $invert=substr($regex,0,1) eq '!';
			$regex=substr($regex,1);
			$regex||='.*';
			next if $invert and $f->{name}=~/$regex/i;
			next if !$invert and $f->{name}!~/$regex/i;
			print "applying $effect on $f->{name}\n";
			my $tempname="$target/".substr(rand(),2,9).".wav";
			system $sox[0],$f->{tempname},$tempname,$effect, grep {$_} (split /\s+/, $args);
			unlink $f->{tempname} unless $f->{tempname} eq "$s->{dir}/$f->{name}";
			$f->{tempname}=$tempname;
		};
		if ($f->{tempname} ne "$s->{dir}/$f->{name}")
		{
			print "reading $f->{name} volume\n";
			my $stat=`$sox[0] "$f->{tempname}" -n stat 2>&1`;
			my $volume=$1 if $stat=~/Volume adjustment:\s+([\d\.]*)/smi;
			$f->{volume}=$volume||1;
		};
		$f->{v}=$f->{volume}/scalar(@{$s->{files}});
		$f->{v}/=2 and print "halfing volume for $f->{name}\n" if $f->{name}=~/\.(L|R)\./;
	};
	printf "mixing $s->{name}.wav (%d left)\n",scalar(keys %sessions)-++$sessions_mixed;

	system @sox, map(("-v $_->{v}",$_->{tempname}), @{$s->{files}}), @format, "$target/$s->{name}.wav";
	foreach my $f (@{$s->{files}})
	{
		unlink $f->{tempname} if $f->{tempname} ne "$s->{dir}/$f->{name}";
	};
	if ($mp3)
	{
		print "encoding $s->{name}.mp3\n";
		system @lame, "$target/$s->{name}.wav","$target/$s->{name}.mp3";
	};
	unlink "$target/$s->{name}.wav" unless $wav;

};

print "completed\n$0 --help for help\n";
