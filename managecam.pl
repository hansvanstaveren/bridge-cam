#!/usr/bin/perl

#
# Software for Bridge_CARE camera setup and backup
#
# Author: Hans van Staveren <sater@xs4all.nl>
#

use strict;
use warnings;

use XML::Simple;
use Data::Dumper;
use LWP::Simple;
use List::Util qw(shuffle);

#
# coldconf is when configuring camera first time
# includes setting IP address
#
my $coldconf;

#
# user/password stuff
# used to have a factory password and default user "admin"
# Since last batch that stuff disappeared
#
my $camuser="brcadmin";
my $resetpw = "wbf123";
my $ourpw = "wbf123";
my $defaultpassword = "wbf123";

my %account_pwd;
my %account_priv;

#
# Ftp stuff for copying video
#
my $ftpuser = "ftpuser";
my $ftppass = "ftp123";
my $default_basedir = "/usbdisk/wtc2021";

#
# Network stuff
#
my $dhcpcamip="";
my $cambase = 0;	# Number to add to camera to get 4th octet IP address
my $cammin = 1;
my $cammax = 800;

#
# Better IP address management
# Gateway will be last usable address
#
my $network_cidr = "172.16.12.0/22";
my $network_ipv4;
my $network_size;
my $network_mask;
my $network_gateway;

# my $hours_after_gmt = 1;
# my $hours_dst = 1;

my $camport = 88;

my $wifinet = "bridge-care";
my $wifipw = "brc-0000";

#
# Recording times
#

my $lowhalf = 20;	# 10h00
my $highhalf = 40;	# 20h00

#
# Backup pre- and suffixes
# and varous flags for wget
#

my @backup_pre = ( "schedule" );
my @backup_suf = ( "avi", "mp4" );
my $quietflag = "-nv";
my $timeoutflag = "--tries=5 --timeout=10";

#
# Network address routines
#

sub network_addr_string {
    my ($ipv4) = @_;

    # print "ipv4=$ipv4, ";
    my $oct4 = $ipv4 & 255;
    $ipv4 >>= 8;
    my $oct3 = $ipv4 & 255;
    $ipv4 >>= 8;
    my $oct2 = $ipv4 & 255;
    $ipv4 >>= 8;
    my $oct1 = $ipv4 & 255;

    # print "oct1-4 are $oct1 $oct2 $oct3 $oct4\n";
    my $addr = "$oct1.$oct2.$oct3.$oct4";
    return $addr;
}

sub network_addr {
    my ($hostnum) = @_;

    my $ipv4 = $network_ipv4 + $hostnum;
    return network_addr_string($ipv4);
}

sub cam_network_addr {
    my ($camnum) = @_;

    # 
    # With more cameras perhaps the mapping cameranumber to IP address
    # should be more flexible.
    # Whatever is decided, this is the place to do it.
    #
    my $hostnum = $camnum;
    if ($hostnum > 200) {
	$hostnum += 56;	# Bump up third octet
    }
    return network_addr($hostnum);
}

sub network_init {

    if ($network_cidr !~ /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)\/([0-9]+)$/) {
	die "network $network_cidr bad format";
    }
    $network_ipv4 = $1*2**24 + $2*2**16 + $3*2**8 + $4;
    $network_size = 2**(32-$5);
    $network_gateway = $network_size - 2;
    my $mask = 2**32-1;
    $mask &= ~($network_size-1);
    $network_mask = network_addr_string($mask);
    # print "ipv4=$network_ipv4, size=$network_size, mask=$network_mask, gateway=$network_gateway\n";
}

#
# End network stuff
#

sub prompt {
    my ($pr) = @_;

    print ("$pr: ");
    my $ans = <>;
    chomp $ans;
    # print "Prompt $pr returning $ans\n";
    return $ans;
}

sub curl {
    my ($cam, $str) = @_;
    my $camip;
    my $pw;

    if ($dhcpcamip ne "") {
	$camip = $dhcpcamip;
	$pw = $resetpw;
    } else {
	$camip = cam_network_addr($cam+$cambase);
	$pw = $ourpw;
    }
    my $prefix = "http://$camip:$camport/cgi-bin/CGIProxy.fcgi?";
    my $auth = "usr=$camuser&pwd=$pw";

    my $curlcmd = "curl -s --connect-timeout 5 '$prefix$auth&$str'";
    print "curlcmd = $curlcmd\n";
    my $res = `$curlcmd`;
    # print "res = $res\n";
    if ($res !~ /</) {
	return 0;
    }
    my $parsed = XMLin($res);

    my $result = $parsed->{result};
    if ($result != 0) {
	print "ERROR $result in command: $curlcmd\n";
    } else {
	# print Dumper($parsed), "\n";
    }
    #
    # Return succes and other stuff. To be used later
    return $result == 0, $parsed;
}

sub sendcmd {
    my ($cam, $cmd, $argptr) = @_;
    my %args = %$argptr;

    # print Dumper(\%args), "\n";
    my $argstr = "";
    foreach my $key (keys%args) {
	$argstr .= "$key=$args{$key}&";
    }
    $argstr .= "cmd=$cmd";
    # print "args = $argstr\n";
    my ($retval, $info) = curl($cam, $argstr);
    #
    # Info is whole result, maybe later
    #
    return $retval;
}

sub sendgetcmd {
    my ($cam, $cmd) = @_;

    my $argstr = "cmd=$cmd";
    # print "args = $argstr\n";
    my ($retval, $info) = curl($cam, $argstr);
    #
    # Info is whole result, maybe later
    #
    return $info;
}

sub get_dev_info {
    my ($cam) = @_;

    my $retval = sendgetcmd($cam, "getDevInfo");
    print "Model: ", $retval->{"productName"}, "\n";
    print "Firmware: ", $retval->{"firmwareVer"}, "\n";
}

sub change_passwd {
    my ($cam, $oldpw, $newpw) = @_;
    my %args;

    $args{usrName} = "$camuser";
    $args{oldPwd} = $oldpw;
    $args{newPwd} = $newpw;
    return sendcmd($cam, "changePassword", \%args);
}

sub set_ip {
    my ($cam) = @_;
    my %args;

    $args{isDHCP} = 0;
    $args{ip} = cam_network_addr($cam+$cambase);
    $args{mask} = $network_mask;
    $args{gate} = network_addr($network_gateway);
    $args{dns1} = network_addr($network_gateway);
    $args{dns2} = network_addr($network_gateway);
    return sendcmd($cam, "setIpInfo", \%args);
}

sub devname {
    my ($cam) = @_;

    return "BRC-$cam";
}

sub set_devname {
    my ($cam) = @_;
    my %args;

    $args{devName} = devname($cam);
    return sendcmd($cam, "setDevName", \%args);
}

sub tz_offset
{
    my $t = time;
    my @l = localtime($t);
    my @g = gmtime($t);

    my $minutes = ($l[2] - $g[2] + ((($l[5]<<9)|$l[7]) <=> (($g[5]<<9)|$g[7])) * 24) * 60 + $l[1] - $g[1];
    return 60*$minutes;
}

sub set_system_time {
    my ($cam) = @_;
    my %args;

    $args{timeSource} = 0;
    $args{ntpServer} = network_addr($network_gateway);
    $args{dateFormat} = 0;
    $args{timeFormat} = 1;
    # $args{timeZone} = -3600*$hours_after_gmt;
    $args{timeZone} = -tz_offset();
    # $args{isDst} = $hours_dst;
    $args{isDst} = 0;
    return sendcmd($cam, "setSystemTime", \%args);
}

sub set_wifi {
    my ($cam) = @_;
    my %args;

    $args{isEnable} = 1;
    $args{isUseWifi} = 1;
    $args{ssid} = $wifinet;
    $args{netType} = 0;
    $args{encryptType} = 3;
    $args{keyFormat} = 0;
    $args{psk} = $wifipw;
    $args{authMode} = 2;
    return sendcmd($cam, "setWifiSetting", \%args);
}

sub set_motion_detect {
    my ($cam, $onoff) = @_;
    my %args;

    $args{isEnable} = $onoff;
    return sendcmd($cam, "setMotionDetectConfig", \%args);
}

sub set_alarm_record {
    my ($cam, $onoff) = @_;
    my %args;

    $args{isEnablePreRecord} = $onoff;
    $args{preRecordSecs} = 5;
    $args{alarmRecordSecs} = 30;
    return sendcmd($cam, "setAlarmRecordConfig", \%args);
}

sub set_infrared_manual {
    my ($cam) = @_;
    my %args;

    $args{mode} = 1;
    return sendcmd($cam, "setInfraLedConfig", \%args);
}

sub set_infrared_off {
    my ($cam) = @_;
    my %args;

    return sendcmd($cam, "closeInfraLed", \%args);
}

sub set_schedule_record {
    my ($cam, $onoff, $wraparound, $audio) = @_;
    my %args;

    $args{isEnable} = $onoff;
    $args{spaceFullMode} = $wraparound ? 0 : 1;
    $args{isEnableAudio} = $audio;
    my $sum = 0;
    foreach my $i ($lowhalf..$highhalf-1) {
	$sum += 2**$i;
    }
    # All days of the week
    $args{schedule0} = $sum;
    $args{schedule1} = $sum;
    $args{schedule2} = $sum;
    $args{schedule3} = $sum;
    $args{schedule4} = $sum;
    $args{schedule5} = $sum;
    $args{schedule6} = $sum;
    return sendcmd($cam, "setScheduleRecordConfig", \%args);
}

sub set_ftp_account {
    my ($cam, $userid, $pass, $privilege) = @_;
    my %args;

    $args{usrName} = $userid;
    $args{usrPwd} = $pass;
    $args{privilege} = $privilege;
    return sendcmd($cam, "addAccount", \%args);
}

sub set_account {
    my ($cam, $userid, $pass, $privilege) = @_;
    my %args;

    $args{usrName} = $userid;
    $args{usrPwd} = $pass;
    $args{privilege} = $privilege;
    return sendcmd($cam, "addAccount", \%args);
}

sub add_accounts {
    my ($cam) = @_;

    foreach my $user (keys %account_pwd) {
	set_account($cam, $user, $account_pwd{$user}, $account_priv{$user});
    }
}

sub account_init {

    open (ACCOUNTS, '<', "accounts") || die "Account info missing";
    while (<ACCOUNTS>) {
	chomp;
	my ($user, $pwd, $priv) = split;
	$pwd = $defaultpassword unless $pwd;
	$priv = 2 unless $priv;
	$account_pwd{$user} = $pwd;
	$account_priv{$user} = $priv;
    }
    close ACCOUNTS;
}

sub start_ftp {
    my ($cam) = @_;
    my %args;

    return sendcmd($cam, "startFtpServer", \%args);
}

sub copy_files {
    my ($cam, $basedir) = @_;

    my $name = devname($cam);
    my $dirname = "$basedir$name";
    my $camip = cam_network_addr($cam+$cambase);
    my $pw = $ourpw;
    my (@copyar, $copystr);

    unless (-d $dirname) { print "Creating directory $dirname\n"; mkdir $dirname }
    chdir $dirname;

    foreach my $pre (@backup_pre) {
	foreach my $suf (@backup_suf) {
	    # print "pre=$pre, suf=$suf\n";
	    push (@copyar, "$pre\\*.$suf");
	}
    }
    $copystr = join ",", @copyar;

    system("(date;echo starting copy)>>Copytimes");

    my $wgetcmd = "wget $quietflag $timeoutflag -a Logfile -A $copystr --mirror -nH -r 'ftp://$ftpuser:$ftppass\@$camip:50021/'";
    print "$wgetcmd\n";
    my $retval = system($wgetcmd);

    system("(date;echo ending copy with return $retval)>>Copytimes");
}

sub copy_files_allcam {
    my ($simul, $continuous, $basedir, @camnumbers) = @_;	## camnumbers array, must be last arg

    # print "Backup cameras @camnumbers in directory $basedir, $simul simultaneous, continuous=$continuous\n";
    do {
	my $cam;
	my @camtocopy;
	my @camdown;
	my $children = 0;

	for $cam (@camnumbers) {
	    if (start_ftp($cam)) {
		# Camera is on, ftp started
		push @camtocopy, $cam;
	    } else {
		# Camera seems off
		push @camdown, $cam;
	    }
	}
	print "Cameras down: @camdown\n";

	@camtocopy = shuffle(@camtocopy);
	print "Will copy cameras in order: @camtocopy\n";

	while ($cam = shift @camtocopy) {
	    if ($children == $simul) {
		# Enough running in background
		# Wait for one to finish
		# print "Wanting to copy $cam, but must wait\n";
		my $pid = wait();
		die "Wait failed" if ($pid < 0);
		$children--;
	    }
	    my $pid = fork();
	    die "Fork failed" unless(defined($pid));
	    if ($pid != 0) {
		# Parent
		$children++;
		print "Started copy of camera $cam, now $children children\n";
	    } else {
		# Child
		copy_files($cam, $basedir);
		exit(0);
	    }
	}

	#
	# Wait for rest of children
	#
	do {
	    print "Waiting for $children children\n";
	    # Nothing
	} while (wait() > 0);
    } while ($continuous);
}

sub splitgrp {
    my @flds = @_;

    my $result = "";
    for (@flds) {
	# print "next field $_\n";
	if (/^([0-9]+)-([0-9]+)$/) {
	    # print "range $1 to $2\n";
	    for ($1..$2) {
		$result = $result . " $_";
	    }
	} else {
	    # print "single number $_\n";
	    $result = $result . " $_";
	}
	# print "Result now: $result\n";
    }
    return $result;
}

#
# Start of main program,
#

network_init();
account_init();

while(1) {
    my $command = prompt("Init or Backup or Groupbackup");
    if ($command =~ /^[Ii].*/) {
	# Init
	my $cam = prompt("Camera number");
	if ($cam < $cammin || $cam > $cammax) {
	    print "Should be between $cammin and $cammax inclusive\n";
	    next;
	}
	$dhcpcamip = prompt("Current IP address if different");
	$coldconf = $dhcpcamip ne "";
	if ($coldconf) {
	    if ($dhcpcamip =~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
		print "Complete IP address $dhcpcamip\n";
	    } elsif ($dhcpcamip =~ /^[0-9]+$/) {
		$dhcpcamip = network_addr($dhcpcamip);
		print "Completed IP address $dhcpcamip\n";
	    } else {
		print "Wrong IP address $dhcpcamip\n";
		next;
	    }

	    $resetpw = "";
	    # change_passwd($cam, $resetpw, $ourpw);
	}
	$resetpw = $ourpw;

	get_dev_info($cam);
	set_devname($cam);
	set_system_time($cam);
	set_wifi($cam);

	set_motion_detect($cam, 0);
	set_alarm_record($cam, 0);
	set_schedule_record($cam, 1, 1, 1);
	set_infrared_manual($cam);
	set_infrared_off($cam);

	add_accounts($cam);

	if ($coldconf) {
	    # And finally (reboot will occur)
	    set_ip($cam);
	}

	$dhcpcamip = "";
    } elsif ($command =~ /^[Bb].*/) {
	# Backup
	my $range=prompt("low-high cam numbers");
	$range =~ /^([0-9]*)(-([0-9]*))?$/;
	my $low = $1;
	my $high = defined($3) ? $3 : $1;
	my $simul = prompt("Simultaneous copies?");
	my $basedir = prompt("Directory for storage [$default_basedir]");
	if ($basedir eq "") {
	    $basedir = $default_basedir;
	}
	$basedir .= "/";
	copy_files_allcam($simul, 0, $basedir, $low..$high);
    } elsif ($command =~ /^[Gg].*/) {
	# Group backup
	my $children=0;
	my $basedir = prompt("Directory for storage [$default_basedir]");
	if ($basedir eq "") {
	    $basedir = $default_basedir;
	}
	$basedir .= "/";

	my $continuousstr = prompt("Continuous or One-time[Continuous]");
	my $continuous;
	if ($continuousstr =~ /^[Oo]/) {
	    $continuous = 0;
	} else {
	    $continuous = 1;
	}
	# print "continuous = $continuous\n";

	open (GROUP, '<', "groupinfo") || die "Group info missing";
	while (<GROUP>) {
	    chomp;
	    my @flds = split;
	    my $simul = shift @flds;
	    # print "Simul $simul, rest @flds\n";
	    my $grprest = splitgrp(@flds);
	    # print "Backup $grprest\n";

	    my $pid = fork();
	    if ($pid == 0) {
		# print "Backup in child $grprest\n";
		my @camnumbers = split(" ", $grprest);
		# print "As array: @camnumbers\n";
		# print "Before copy continuous=$continuous\n";
		copy_files_allcam($simul, $continuous, $basedir, @camnumbers);
		exit(0);
	    } else {
		$children++;
	    }
	}
	close GROUP;
	for (1..$children) {
	    my $pid = wait();
	}
    } else {
	print "Goodbye!\n";
	last;
    }
}
