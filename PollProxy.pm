# PollProxy::fetch(), ::populate_proxies(), and ::markBad()
# are the only external entry points.

# fetch(ua, url, [noproxy])
# ua: LWP::UserAgent
# url: string of the url to fetch
# noproxy: if defined, do not proxy this request
#
# returns HTTP::Response object implementing:
#   is_success, status_line, content, content_type

# populate_proxies(content)
# content: HTML-formatted proxy list
# returns number of new proxies added

# markBad(reason)
# reason: string describing why the proxy is considered to have failed

use strict;
use warnings;
use FindBin;
use DBI;

package PollProxy;

$PollProxy::DATADIR = ${FindBin::Bin}.'/../proxydb';
(-d $PollProxy::DATADIR) or die "Could not find ${PollProxy::DATADIR}";

sub process_content;
sub proxy;
sub get_proxies;
sub markGood;
sub markBad;

sub fetch {
    my $ua = shift;
    my $url = shift;
    my $noproxy = shift;

    my $req = HTTP::Request->new(GET => $url);
    my $res;
    my $tries = 0;

    if (!$noproxy) {
	if (!defined($PollProxy::CURRENT_PROXY)) {
	    unless (@PollProxy::PROXY_LIST) {
		unless (@PollProxy::PROXY_LIST = PollProxy::get_proxies) {
		    die "No proxy list!";
		}
	    }
	    $PollProxy::CURRENT_PROXY
		= $PollProxy::PROXY_LIST[int(rand($#PollProxy::PROXY_LIST+1))];
	    unless ($PollProxy::CURRENT_PROXY) {
		# This can't actually happen if there is a valid proxy list
		die "No proxies!";
	    }
	    PollProxy::proxy($ua, $PollProxy::CURRENT_PROXY);
	}
    }
    do {
	print "Trying $url... ";
	$res = $ua->request($req);
	print $res->status_line . "\n";
	# XXX: What is the difference between
	# 200 OK
	# and
	# 200 Assumed OK
	# because they are both is_success but the second is NOT OK!!!
	# sometimes it's a proxy not being able to resolve the host,
        # or for some reason it gets a read timeout
# Trying http://host.example/foo/bar/... 200 Assumed OK
# Trying http://sub.host.example/baz/quux/000.gif... 500 read timeout

	if ($res->is_success) {
	    markGood;
	    if ($res->content =~
		/^<META HTTP-EQUIV="refresh" CONTENT="\d+; URL=([^"]+)">/){#"{
		my $follow = $1;
		if ($follow =~ m!^(http://[\w\.]+\.\w+)\.(/.+)$!) {
		    if ($1.$2 eq $url) {
			print STDERR "CoDeeN redirect bug: $1][$2\n";
			return fetch($ua, $url);
			# CoDeeN for some reason messes up their redirect,
			# http://foo.com/bar -> http://foo.com./bar
		    }
		}
	    }
	    return $res;
	} elsif ($res->status_line =~ /^404/) {
	    # Content is not available, don't bother retrying
	    return $res;
	}
	sleep(1);
    } while (++$tries < $PollProxy::max_tries);
    markBad($res->status_line);
    return $res;
}

sub proxy {
    my $ua = shift;
    my $location = shift;
    print "Using proxy $location\n";
    $ua->proxy('http', 'http://' . $location);
}

sub get_proxies {
    my $dbh = DBI->connect ("DBI:CSV:f_dir=${PollProxy::DATADIR}") or
	die "Cannot connect: $DBI::errstr";
    my $proxyref = $dbh->selectall_arrayref("SELECT proxy FROM proxy"
					    ." WHERE failure=0");
    return map { $_->[0] } @{$proxyref};
}

# takes HTML-formatted proxy list and inserts new entries to db
# returns number of new proxies added
sub populate_proxies {
    my $content = shift;

    $content =~ s/^(.+Anonymous HTTP proxies)//s;
    $content =~ s/(Free HTTPS proxy list.+)$//s;
    my @proxies = process_content $content;
    print "Total " . (1+$#proxies) . " proxies discovered:\n";
    if ($#proxies < 0) { # no proxies
	    my $dump = "/tmp/out-$$.html";
	    open F, ">$dump" or die $!;
	    print F $content;
	    close F;
	    print "Logged content to $dump\n";
    }
#    for my $proxy (@proxies) {
#	print " $proxy\n";
#    }
    my $dbh = DBI->connect ("DBI:CSV:f_dir=${PollProxy::DATADIR}") or
	die "Cannot connect: $DBI::errstr";
    my $sth = $dbh->prepare("SELECT proxy FROM proxy WHERE proxy=?");
    my @newProxies = grep {
	$sth->execute($_);
	! $sth->fetch;
    } @proxies;

    print "Found " . (1+$#newProxies) . " new proxies.\n";
    $sth = $dbh->prepare("INSERT INTO proxy (proxy,last,success,failure) VALUES"
			 . " (?,?,?,?)");
    for my $proxy (@newProxies) {
	$sth->execute($proxy, 0, 0, 0);
    }
    
    $dbh->disconnect;
    return 1+$#newProxies;
}

# Process content of proxy page
sub process_content {
    my $content = shift;
    my @proxies = ();

    while ($content =~
	   m{
 name = '((\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3}))';
 port1 = (\d+);
 port2 = (\d+);
 port3 = (\d+);
 port4 = (\d+);
 port5 = (\d+);
 port6 = (\d+);
 port7 = (\d+);
 port8 = (\d+);
 port9 = (\d+);
 port10 = (\d+);
 \w+ = port(\d+) \+ \((\d+)-(\d+)\) / (\d+);
}g) {
	my $location = $1;
	my $ok = 1;
	my @q = ($2, $3, $4, $5);

	my @port_seed = ($6, $7, $8, $9, $10, $11, $12, $13, $14, $15);
	my $port_index = $16;
	my $port_offset = ($17-$18)/$19;

	for my $q (@q) {
	    if (($q < 0) or ($q > 255)) {
		$ok = 0;
	    }
	}
	my $port = $port_seed[$port_index-1] + $port_offset;
	unless ($port > 0) { $ok = 0; }

	if ($ok) {
	    push @proxies, $location . ":$port";
	}
    }
    @proxies;
}

sub markGood {
    return unless $PollProxy::CURRENT_PROXY;
    my $dbh = DBI->connect ("DBI:CSV:f_dir=${PollProxy::DATADIR}") or
	die "Cannot connect: $DBI::errstr";
    print "Select\n";
    my $rref = $dbh->selectall_arrayref("SELECT success FROM proxy WHERE proxy=?"
					. " LIMIT 1",
					{}, $PollProxy::CURRENT_PROXY);
    my $success = $rref->[0]->[0];
    print "Update\n";
    my $sth = $dbh->prepare("UPDATE proxy SET last=?,success=? WHERE proxy=?");
    # Use of uninitialized value in addition (+) at PollProxy.pm line 207.
    ## XXX first time $success may be undefined? 
    $sth->execute(time, 1+$success, $PollProxy::CURRENT_PROXY);
    $dbh->disconnect;
}

sub markBad {
    my $reason = shift;
    my $dbh = DBI->connect ("DBI:CSV:f_dir=${PollProxy::DATADIR}") or
	die "Cannot connect: $DBI::errstr";
    my $sth = $dbh->prepare("UPDATE proxy SET failure=? WHERE proxy=?");
    $sth->execute($reason, $PollProxy::CURRENT_PROXY);
    $dbh->disconnect;
}

@PollProxy::PROXY_LIST = ();
$PollProxy::CURRENT_PROXY = undef;
$PollProxy::max_tries = 10;

1;
