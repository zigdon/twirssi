use strict;
use Irssi;
use Irssi::Irc;
use HTTP::Date;
use HTML::Entities;
use File::Temp;
use LWP::Simple;
use Data::Dumper;
use Encode;
use FileHandle;
use POSIX qw/:sys_wait_h strftime/;
use Net::Twitter qw/3.11009/;
use DateTime;
use DateTime::Format::Strptime;
$Data::Dumper::Indent = 1;

use vars qw($VERSION %IRSSI);

$VERSION = "2.5.1beta";
%IRSSI   = (
    authors     => 'Dan Boger',
    contact     => 'zigdon@gmail.com',
    name        => 'twirssi',
    description => 'Send twitter updates using /tweet.  '
      . 'Can optionally set your bitlbee /away message to same',
    license => 'GNU GPL v2',
    url     => 'http://twirssi.com',
    changed => 'Fri Jan 22 14:40:48 PST 2010',
);

my $twit;
my %twits;
my %oauth;
my $user;
my $defservice;
my $poll;
my $last_poll;
my $last_friends_poll = 0;
my $last_blocks_poll = 0;
my %nicks;                      # $nicks{$screen_name} = last seen/mentioned time
my %friends;
my %blocks;
my %tweet_cache;
my %state;
my $failstatus = 0;
my $first_call = 1;
my $child_pid;
my %fix_replies_index;
my %search_once;
my $update_is_running = 0;
my %logfile;
my %settings;
my %last_ymd;
my @datetime_parser;
my $local_tz = DateTime::TimeZone->new( name => 'local' );

my %meta_to_twit = (    # map file keys to twitter keys
        'id'		=> 'id',
	'created_at'    => 'created_at',
        'reply_to_user'	=> 'in_reply_to_screen_name',
        'reply_to_id'	=> 'in_reply_to_status_id',
);

my %irssi_to_mirc_colors = (
    '%k' => '01',
    '%r' => '05',
    '%g' => '03',
    '%y' => '07',
    '%b' => '02',
    '%m' => '06',
    '%c' => '10',
    '%w' => '15',
    '%K' => '14',
    '%R' => '04',
    '%G' => '09',
    '%Y' => '08',
    '%B' => '12',
    '%M' => '13',
    '%C' => '11',
    '%W' => '00',
);

sub cmd_direct {
    my ( $data, $server, $win ) = @_;

    return unless &logged_in($twit);

    my ( $target, $text ) = split ' ', $data, 2;
    unless ( $target and $text ) {
        &notice( ["dm"], "Usage: /dm <nick> <message>" );
        return;
    }

    &cmd_direct_as( "$user $data", $server, $win );
}

sub cmd_direct_as {
    my ( $data, $server, $win ) = @_;

    return unless &logged_in($twit);

    my ( $username, $target, $text ) = split ' ', $data, 3;
    unless ( $username and $target and $text ) {
        &notice( ["dm"], "Usage: /dm_as <username> <nick> <message>" );
        return;
    }

    return unless $username = &valid_username($username);

    return if &too_long($text);

    $text = &make_utf8($text);

    eval {
        if ( $twits{$username}
            ->new_direct_message( { user => $target, text => $text } ) )
        {
            &notice( [ "dm", $target ], "DM sent to $target: $text" );
            $nicks{$target} = time;
        } else {
            my $error;
            eval {
                $error = JSON::Any->jsonToObj( $twits{$username}->get_error() );
                $error = $error->{error};
            };
            die $error if $error;
            &notice( [ "dm", $target ], "DM to $target failed" );
        }
    };

    if ($@) {
        &notice( ["dm"], "DM caused an error: $@" );
        return;
    }
}

sub cmd_retweet {
    my ( $data, $server, $win ) = @_;

    return unless &logged_in($twit);

    $data =~ s/^\s+|\s+$//;
    unless ($data) {
        &notice( [ "tweet", $user ], "Usage: /retweet <nick[:num]> [comment]" );
        return;
    }

    (my $id, $data ) = split ' ', $data, 2;

    &cmd_retweet_as( "$user $id $data", $server, $win );
}

sub cmd_retweet_as {
    my ( $data, $server, $win ) = @_;

    return unless &logged_in($twit);

    $data =~ s/^\s+|\s+$//;
    ( my $username, my $id, $data ) = split ' ', $data, 3;

    unless ($username) {
        &notice( ["tweet"],
            "Usage: /retweet_as <username> <nick[:num]> [comment]" );
        return;
    }

    return unless $username = &valid_username($username);

    my $nick;
    $id =~ s/[^\w\d\-:]+//g;
    ( $nick, $id ) = split /:/, $id;
    unless ( exists $state{__ids}{ lc $nick } ) {
        &notice( [ "tweet", $username ],
            "Can't find a tweet from $nick to retweet!" );
        return;
    }

    $id = $state{__indexes}{lc $nick} unless $id;
    unless ( $state{__ids}{ lc $nick }[$id] ) {
        &notice( [ "tweet", $username ],
            "Can't find a tweet numbered $id from $nick to retweet!" );
        return;
    }

    unless ( $state{__tweets}{ lc $nick }[$id] ) {
        &notice( [ "tweet", $username ],
            "The text of this tweet isn't saved, sorry!" );
        return;
    }

# Irssi::settings_add_str( "twirssi", "twirssi_retweet_format", 'RT $n: $t ${-- $c$}' );
    my $text = $settings{retweet_format};
    $text =~ s/\$n/\@$nick/g;
    if ($data) {
        $text =~ s/\${|\$}//g;
        $text =~ s/\$c/$data/;
    } else {
        $text =~ s/\${.*?\$}//;
    }
    $text =~ s/\$t/$state{__tweets}{ lc $nick }[$id]/;

    my $modified = $data;
    $data = &shorten($text);

    return if $modified and &too_long($data);

    $data = &make_utf8($data);

    my $success = 1;
    eval {
        if ($modified)
        {
            $success = $twits{$username}->update(
                {
                    status => $data,

                    # in_reply_to_status_id => $state{__ids}{ lc $nick }[$id]
                }
            );
        } else {
            $success =
              $twits{$username}->retweet( { id => $state{__ids}{ lc $nick }[$id] } );
            $success = $success->{id} if ref $success;
        }
        &notice( [ "tweet", $username ], "Update failed" ) unless $success;
    };
    return unless $success;

    if ($@) {
        &notice( [ "tweet", $username ],
            "Update caused an error: $@.  Aborted" );
        return;
    }

    foreach ( $data =~ /@([-\w]+)/g ) {
        $nicks{$_} = time;
    }

    &notice( [ "tweet", $username ], "Retweet sent" );
}

sub cmd_tweet {
    my ( $data, $server, $win ) = @_;

    return unless &logged_in($twit);

    $data =~ s/^\s+|\s+$//;
    unless ($data) {
        &notice( ["tweet"], "Usage: /tweet <update>" );
        return;
    }

    &cmd_tweet_as( "$user\@$defservice $data", $server, $win );
}

sub cmd_tweet_as {
    my ( $data, $server, $win ) = @_;

    return unless &logged_in($twit);

    $data =~ s/^\s+|\s+$//;
    $data =~ s/\s\s+/ /g;
    ( my $username, $data ) = split ' ', $data, 2;

    unless ( $username and $data ) {
        &notice( ["tweet"], "Usage: /tweet_as <username> <update>" );
        return;
    }

    return unless $username = &valid_username($username);

    $data = &shorten($data);

    return if &too_long($data);

    $data = &make_utf8($data);

    my $success = 1;
    my $res;
    eval {
        unless ( $res = $twits{$username}->update($data) )
        {
            &notice( [ "tweet", $username ], "Update failed" );
            $success = 0;
        }
    };
    return unless $success;

    if ($@) {
        &notice( [ "tweet", $username ],
            "Update caused an error: $@.  Aborted." );
        return;
    }

    foreach ( $data =~ /@([-\w]+)/g ) {
        $nicks{$_} = time;
    }

    $state{__last_tweet}{$username} = $res->{id};

    if ( $username eq "$user\@$defservice" ) {
        my $away = &update_away($data);

        &notice( [ "tweet", $username ],
            "Update sent" . ( $away ? " (and away msg set)" : "" ) );
    } else {
        &notice( [ "tweet", $username ], "Update sent" );
    }
}

sub cmd_broadcast {
    my ( $data, $server, $win ) = @_;

    my $setting = $settings{broadcast_users};
    my @bcast_users;
    if ($setting) {
        @bcast_users = split /\s*,\s*/, $setting;
    } else {
        @bcast_users = keys %twits;
    }

    foreach my $buser (@bcast_users) {
        &cmd_tweet_as( "$buser $data", $server, $win );
    }
}

sub cmd_info {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//g;
    unless ( $data ) {
        &notice( ["info"], "Usage: /twitter_info <nick[:num]>" );
        return;
    }

    $data =~ s/[^\w\-:]+//g;
    my ( $nick_orig, $id ) = split /:/, $data;
    my $nick = lc $nick_orig;
    unless ( exists $state{__ids}{ $nick } ) {
        &notice( [ "info" ],
            "Can't find any tweet from $nick_orig!" );
        return;
    }

    $id = $state{__indexes}{$nick} unless defined $id;
    my $statusid = $state{__ids}{$nick}[$id];
    unless ( $statusid ) {
        &notice( [ "info" ],
            "Can't find a tweet numbered $id from $nick_orig!" );
        return;
    }

    my $username      = $state{__usernames}{$nick}[$id];
    my $timestamp     = $state{__created_ats}{$nick}[$id];
    my $tweet         = $state{__tweets}{$nick}[$id];
    my $reply_to_id   = $state{__reply_to_ids}{$nick}[$id];
    my $reply_to_user = $state{__reply_to_users}{$nick}[$id];

    my $url = '';
    if ( defined $username ) {
        if ( $username =~ /\@Twitter/ ) {
            $url = "http://twitter.com/$nick/statuses/$statusid";
        } elsif ( $username =~ /\@Identica/ ) {
            $url = "http://identi.ca/notice/$statusid";
        }
    }

    &notice( [ "info" ], ",--------- $nick:$id" );
    &notice( [ "info" ], "| nick:    $nick_orig <http://twitter.com/$nick_orig>" );
    &notice( [ "info" ], "| id:      $statusid" . ($url ? " <$url>" : ''));
    &notice( [ "info" ], "| time:    " . ($timestamp
                             ? DateTime->from_epoch( epoch => $timestamp, time_zone => $local_tz)
                             : '<unknown>') );
    &notice( [ "info" ], "| account: " . ($username ? $username : '<unknown>' ) );
    &notice( [ "info" ], "| text:    " . ($tweet ? $tweet : '<unknown>' ) );

    if ($reply_to_id and $reply_to_user) {
       &notice( [ "info" ], "| ReplyTo: $reply_to_user:$reply_to_id" );
    }
    &notice( [ "info" ], "`---------" );
}

sub cmd_reply {
    my ( $data, $server, $win ) = @_;

    return unless &logged_in($twit);

    $data =~ s/^\s+|\s+$//;
    unless ($data) {
        &notice( ["reply"], "Usage: /reply <nick[:num]> <update>" );
        return;
    }

    ( my $id, $data ) = split ' ', $data, 2;
    unless ( $id and $data ) {
        &notice( ["reply"], "Usage: /reply <nick[:num]> <update>" );
        return;
    }

    &cmd_reply_as( "$user $id $data", $server, $win );
}

sub cmd_reply_as {
    my ( $data, $server, $win ) = @_;

    return unless &logged_in($twit);

    $data =~ s/^\s+|\s+$//;
    ( my $username, my $id, $data ) = split ' ', $data, 3;

    unless ( $username and $data ) {
        &notice( ["reply"],
            "Usage: /reply_as <username> <nick[:num]> <update>" );
        return;
    }

    return unless $username = &valid_username($username);

    my $nick;
    $id =~ s/[^\w\d\-:]+//g;
    ( $nick, $id ) = split /:/, $id;
    unless ( exists $state{__ids}{ lc $nick } ) {
        &notice( [ "reply", $username ],
            "Can't find a tweet from $nick to reply to!" );
        return;
    }

    $id = $state{__indexes}{lc $nick} unless $id;
    unless ( $state{__ids}{ lc $nick }[$id] ) {
        &notice( [ "reply", $username ],
            "Can't find a tweet numbered $id from $nick to reply to!" );
        return;
    }

    $data = "\@$nick $data";
    $data = &shorten($data);

    return if &too_long($data);

    $data = &make_utf8($data);

    my $success = 1;
    eval {
        unless (
            $twits{$username}->update(
                {
                    status                => $data,
                    in_reply_to_status_id => $state{__ids}{ lc $nick }[$id]
                }
            )
          )
        {
            &notice( [ "reply", $username ], "Update failed" );
            $success = 0;
        }
    };
    return unless $success;

    if ($@) {
        &notice( [ "reply", $username ],
            "Update caused an error: $@.  Aborted" );
        return;
    }

    foreach ( $data =~ /@([-\w]+)/g ) {
        $nicks{$_} = time;
    }

    my $away = &update_away($data);

    &notice( [ "reply", $username ],
        "Update sent" . ( $away ? " (and away msg set)" : "" ) );
}

sub gen_cmd {
    my ( $usage_str, $api_name, $post_ref, $data_ref ) = @_;

    return sub {
        my ( $data, $server, $win ) = @_;

        return unless &logged_in($twit);

        if ($data_ref) {
            $data = $data_ref->($data);
        }

        $data =~ s/^\s+|\s+$//;
        unless ($data) {
            &notice("Usage: $usage_str");
            return;
        }

        my $success = 1;
        eval {
            unless ( $twit->$api_name($data) )
            {
                &notice("$api_name failed");
                $success = 0;
            }
        };
        return unless $success;

        if ($@) {
            &notice("$api_name caused an error.  Aborted: $@");
            return;
        }

        &$post_ref($data) if $post_ref;
      }
}

sub cmd_search {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//g;
    if ( length $data > 0 ) {
        my $username = &normalize_username($user);
        if ( exists $search_once{$username}->{$data} ) {
            &notice( [ "search", $data ], "Search is already queued" );
            return;
        }
        $search_once{$username}->{$data} = $settings{search_results};
        &notice( [ "search", $data ], "Searching for '$data'" );
        &get_updates;
    } else {
        &notice( ["search"], "Usage: /twitter_search <search term>" );
    }
}

sub cmd_switch {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//g;
    $data = &normalize_username($data);
    if ( exists $twits{$data} ) {
        &notice( [ "tweet", $data ], "Switching to $data" );
        $twit = $twits{$data};
        if ( $data =~ /(.*)\@(.*)/ ) {
            $user       = $1;
            $defservice = $2;
        } else {
            &notice( [ "tweet", $data ],
                "Couldn't figure out what service '$data' is on" );
        }
    } else {
        &notice( ["tweet"], "Unknown user $data" );
    }
}

sub cmd_logout {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//g;
    $data = $user unless $data;
    return unless $data = &valid_username($data);

    &notice( [ "tweet", $data ], "Logging out $data..." );
    eval { $twits{$data}->end_session(); };
    delete $twits{$data};
    undef $twit;
    if ( keys %twits ) {
        &cmd_switch( ( keys %twits )[0], $server, $win );
    } else {
        Irssi::timeout_remove($poll) if $poll;
        undef $poll;
    }
}

sub cmd_login {
    my ( $data, $server, $win ) = @_;
    my $pass;
    &debug("logging in: $data");
    if ($data) {
        &debug("manual data login");
        ( $user, $pass ) = split ' ', $data, 2;
        unless ( $settings{use_oauth} or $pass ) {
            &notice( ["tweet"],
                "usage: /twitter_login <username>[\@<service>] <password>" );
            return;
        }
    } elsif ( $settings{use_oauth} and my $autouser = $settings{usernames} ) {
        &debug("oauth autouser login");
        foreach my $user ( split /,/, $autouser ) {
            &cmd_login($user);
        }
        return;
    } elsif ( $autouser = $settings{usernames}
        and my $autopass = $settings{passwords} )
    {
        &debug("autouser login");
        my @user = split /\s*,\s*/, $autouser;
        my @pass = split /\s*,\s*/, $autopass;

        # if a password ends with a '\', it was meant to escape the comma, and
        # it should be concatinated with the next one
        my @unescaped;
        while (@pass) {
            my $p = shift @pass;
            while ( $p =~ /\\$/ and @pass ) {
                $p .= "," . shift @pass;
            }
            push @unescaped, $p;
        }

        if ( @user != @unescaped ) {
            &notice( ["error"],
                    "Number of usernames doesn't match "
                  . "the number of passwords - auto-login failed" );
        } else {
            my ( $u, $p );
            while ( @user and @unescaped ) {
                $u = shift @user;
                $p = shift @unescaped;
                &cmd_login("$u $p");
            }
            return;
        }
    } else {
        &notice( ["error"],
                "/twitter_login requires either a username/password "
              . "or twitter_usernames and twitter_passwords to be set. "
              . "Note that if twirssi_use_oauth is true, passwords are "
              . "not required" );
        return;
    }

    %blocks = %friends = %nicks = ();

    my $service;
    if ( $user =~ /^(.*)@(Twitter|Identica)$/ ) {
        ( $user, $service ) = ( $1, $2 );
    } else {
        $service = $settings{default_service};
    }
    $defservice = $service = ucfirst lc $service;
    $user = lc $user;  # similar to normalize_username($user @ $service)

    if (    $service eq 'Twitter'
        and $settings{use_oauth} )
    {
        &debug("$user\@$service: Attempting OAuth");
        eval {
            if ( $service eq 'Identica' )
            {
                $twit = Net::Twitter->new(
                    identica => 1,
                    traits   => [ 'API::REST', 'API::Search' ],
                    source   => "twirssi",
                    ssl      => !$settings{avoid_ssl},
                );
            } else {
                $twit = Net::Twitter->new(
                    traits =>
                      [ 'API::REST', 'OAuth', 'API::Search', 'RetryOnError' ],
                    (
                        grep tr/a-zA-Z/n-za-mN-ZA-M/, map $_,
                        pbafhzre_xrl => 'OMINiOzn4TkqvEjKVioaj',
                        pbafhzre_frperg =>
                          '0G5xnujYlo34ipvTMftxN9yfwgTPD05ikIR2NCKZ',
                    ),
                    source => "twirssi",
                    ssl    => !$settings{avoid_ssl},
                );
            }
        };

        if ($@) {
            &notice( ["error"], "Error when creating object:  $@" );
        }

        if ($twit) {
            if ( open( OAUTH, $settings{oauth_store} ) ) {
                while (<OAUTH>) {
                    chomp;
                    next unless /^$user\@$service (\S+) (\S+)/i;
                    &debug("$user\@$service: Trying cached oauth creds");
                    $twit->access_token($1);
                    $twit->access_token_secret($2);
                    last;
                }
                close OAUTH;
            }

            unless ( $twit->authorized ) {
                my $url;
                eval { $url = $twit->get_authorization_url; };

                if ($@) {
                    &notice( ["error"],
                        "ERROR: Failed to get OAuth authorization_url: $@" );
                    return;
                }
                &notice(
                    ["error"],
                    "$user: Twirssi not authorized to access $service.",
                    "Please authorize at the following url, then enter the PIN",
                    "supplied with /twirssi_oauth $user\@$service <pin>",
                    $url
                );

                $oauth{pending}{"$user\@$service"} = $twit;
                return;
            }
        }
    } else {
        $twit = Net::Twitter->new(
            $service eq 'Identica' ? ( identica => 1 ) : (),
            username => $user,
            password => $pass,
            source   => "twirssi",
            ssl      => $settings{avoid_ssl},
        );
    }

    unless ($twit) {
        &notice( ["error"], "Failed to create object!  Aborting." );
        return;
    }

    return &verify_twitter_object( $server, $win, $user, $service, $twit );
}

sub cmd_oauth {
    my ( $data, $server, $win ) = @_;
    my ( $key, $pin ) = split ' ', $data;
    my ( $user, $service );
    $key = &normalize_username($key);
    if ( $key =~ /^(.*)@(Twitter|Identica)$/ ) {
        ( $user, $service ) = ( $1, $2 );
    }
    $pin =~ s/\D//g;
    &debug("Applying pin to $key");

    unless ( exists $oauth{pending}{$key} ) {
        &notice( ["error"],
                "There isn't a pending oauth request for $key. "
              . "Try /twitter_login first" );
        return;
    }

    my $twit = $oauth{pending}{$key};
    my ( $access_token, $access_token_secret );
    eval {
        ( $access_token, $access_token_secret ) =
          $twit->request_access_token( verifier => $pin );
    };

    if ($@) {
        &notice( ["error"], "Invalid pin, try again." );
        return;
    }

    delete $oauth{pending}{$key};

    my $store_file = $settings{oauth_store};
    if ($store_file) {
        my @store;
        if ( open( OAUTH, $store_file ) ) {
            while (<OAUTH>) {
                chomp;
                next if /$key/i;
                push @store, $_;
            }
            close OAUTH;

        }

        push @store, "$key $access_token $access_token_secret";

        if ( open( OAUTH, ">$store_file.new" ) ) {
            print OAUTH "$_\n" foreach @store;
            close OAUTH;
            rename "$store_file.new", $store_file
              or &notice( ["error"], "Failed to rename $store_file.new: $!" );
        } else {
            &notice( ["error"], "Failed to write $store_file.new: $!" );
        }
    } else {
        &notice( ["error"],
                "No persistant storage set for OAuth.  "
              . "Please /set twirssi_oauth_store to a writable filename." );
    }

    return &verify_twitter_object( $server, $win, $user, $service, $twit );
}

sub verify_twitter_object {
    my ( $server, $win, $user, $service, $twit ) = @_;

    if ( my $timeout = $settings{timeout} and $twit->can('ua') ) {
        $twit->ua->timeout($timeout);
        &notice( ["tweet"], "Twitter timeout set to $timeout" );
    }

    unless ( $twit->verify_credentials() ) {
        &notice(
            [ "tweet", "$user\@$service" ],
            "Login as $user\@$service failed"
        );

        if ( not $settings{avoid_ssl} ) {
            &notice(
                [ "tweet", "$user\@$service" ],
                "It's possible you're missing one of the modules required for "
                  . "SSL logins.  Try setting twirssi_avoid_ssl to on.  See "
                  . "http://cpansearch.perl.org/src/GAAS/libwww-perl-5.831/README.SSL "
                  . "for the detailed requirements."
            );
        }

        $twit = undef;
        if ( keys %twits ) {
            &cmd_switch( ( keys %twits )[0], $server, $win );
        }
        return;
    }

    my $rate_limit = $twit->rate_limit_status();
    if ( $rate_limit and $rate_limit->{remaining_hits} < 1 ) {
        &notice( [ "tweet", "$user\@$service" ],
            "Rate limit exceeded, try again after $rate_limit->{reset_time}" );
        $twit = undef;
        return;
    }

    &debug("$user\@$service: saving object");
    $twits{"$user\@$service"} = $twit;
    Irssi::timeout_remove($poll) if $poll;
    $poll = Irssi::timeout_add( &get_poll_time * 1000, \&get_updates, "" );
    &notice( [ "tweet", "$user\@$service" ],
        "Logged in as $user\@$service, loading friends list and blocks..." );
    &load_friends($twit, "$user\@$service");
    &notice( [ "tweet", "$user\@$service" ],
        "loaded friends: " . scalar keys %{ $friends{"$user\@$service"} } );
    &load_blocks($twit, "$user\@$service");
    &notice( [ "tweet", "$user\@$service" ],
        "loaded blocks: " . scalar keys %{ $blocks{"$user\@$service"} } );

    foreach my $scr_name (keys %{ $friends{"$user\@$service"} }) {
        $nicks{$scr_name} = $friends{"$user\@$service"}{$scr_name};
    }
    $nicks{$user} = 0;
    return 1;
}

sub cmd_add_follow {
    my ( $data, $server, $win ) = @_;

    unless ($data) {
        &notice( ["error"], "Usage: /twitter_add_follow_extra <username>" );
        return;
    }

    $data =~ s/^\s+|\s+$//g;
    $data =~ s/^\@//;
    $data = lc $data;

    if ( exists $state{__fixreplies}{"$user\@$defservice"}{$data} ) {
        &notice( ["tweet"], "Already following all replies by \@$data" );
        return;
    }

    $state{__fixreplies}{"$user\@$defservice"}{$data} = 1;
    &notice( ["tweet"], "Will now follow all replies by \@$data" );
}

sub cmd_del_follow {
    my ( $data, $server, $win ) = @_;

    unless ($data) {
        &notice( ["error"], "Usage: /twitter_del_follow_extra <username>" );
        return;
    }

    $data =~ s/^\s+|\s+$//g;
    $data =~ s/^\@//;
    $data = lc $data;

    unless ( exists $state{__fixreplies}{"$user\@$defservice"}{$data} ) {
        &notice( ["error"], "Wasn't following all replies by \@$data" );
        return;
    }

    delete $state{__fixreplies}{"$user\@$defservice"}{$data};
    &notice( ["tweet"], "Will no longer follow all replies by \@$data" );
}

sub cmd_list_follow {
    my ( $data, $server, $win ) = @_;

    my $found = 0;
    foreach my $suser ( sort keys %{ $state{__fixreplies} } ) {
        my $frusers;
        foreach my $fruser ( sort keys %{ $state{__fixreplies}{$suser} } ) {
            $frusers = $frusers ? "$frusers, $fruser" : $fruser;
        }
        if ($frusers) {
            $found = 1;
            &notice( ["tweet"], "Following all replies as \@$suser: $frusers" );
        }
    }

    unless ($found) {
        &notice( ["tweet"], "Not following all replies by anyone" );
    }
}

sub cmd_add_search {
    my ( $data, $server, $win ) = @_;

    unless ( $twit and $twit->can('search') ) {
        &notice( ["search"],
                "ERROR: Your version of Net::Twitter ($Net::Twitter::VERSION) "
              . "doesn't support searches." );
        return;
    }

    $data =~ s/^\s+|\s+$//g;
    $data = lc $data;
    my $want_win = 1 if $data =~ s/^-w\s+//;

    unless ($data) {
        &notice( ["search"], "Usage: /twitter_subscribe [-w] <topic>" );
        return;
    }

    if ( exists $state{__searches}{"$user\@$defservice"}{$data} ) {
        &notice( [ "search", $data ],
            "Already had a subscription for '$data'" );
        return;
    }

    $state{__searches}{"$user\@$defservice"}{$data} = 1;
    &notice( [ "search", $data ], "Added subscription for '$data'" );
    &cmd_set_window("search $data $data", $server, $win) if $want_win;
}

sub cmd_del_search {
    my ( $data, $server, $win ) = @_;

    unless ( $twit and $twit->can('search') ) {
        &notice( ["search"],
                "ERROR: Your version of Net::Twitter ($Net::Twitter::VERSION) "
              . "doesn't support searches." );
        return;
    }
    $data =~ s/^\s+|\s+$//g;
    $data = lc $data;

    unless ($data) {
        &notice( ["search"], "Usage: /twitter_unsubscribe <topic>" );
        return;
    }

    unless ( exists $state{__searches}{"$user\@$defservice"}{$data} ) {
        &notice( [ "search", $data ], "No subscription found for '$data'" );
        return;
    }

    delete $state{__searches}{"$user\@$defservice"}{$data};
    &notice( [ "search", $data ], "Removed subscription for '$data'" );
}

sub cmd_list_search {
    my ( $data, $server, $win ) = @_;

    my $found = 0;
    foreach my $suser ( sort keys %{ $state{__searches} } ) {
        my $topics;
        foreach my $topic ( sort keys %{ $state{__searches}{$suser} } ) {
            $topics = $topics ? "$topics, $topic" : $topic;
        }
        if ($topics) {
            $found = 1;
            &notice( ["search"], "Search subscriptions for $suser: $topics" );
        }
    }

    unless ($found) {
        &notice( ["search"], "No search subscriptions set up" );
    }
}

sub cmd_upgrade {
    my ( $data, $server, $win ) = @_;

    my $loc = $settings{location};
    unless ( -w $loc ) {
        &notice( ["error"],
                "$loc isn't writable, can't upgrade."
              . "  Perhaps you need to /set twirssi_location?" );
        return;
    }

    my $md5;
    unless ( $data or $settings{upgrade_beta} ) {
        eval { use Digest::MD5; };

        if ($@) {
            &notice( ["error"],
                    "Failed to load Digest::MD5."
                  . "  Try '/twirssi_upgrade nomd5' to skip MD5 verification" );
            return;
        }

        $md5 = get("http://twirssi.com/md5sum");
        chomp $md5;
        $md5 =~ s/ .*//;
        unless ($md5) {
            &notice( ["error"],
                "Failed to download md5sum from peeron!  Aborting." );
            return;
        }

        unless ( open( CUR, $loc ) ) {
            &notice( ["error"],
                    "Failed to read $loc."
                  . "  Check that /set twirssi_location is set to the correct location."
            );
            return;
        }

        my $cur_md5 = Digest::MD5::md5_hex(<CUR>);
        close CUR;

        if ( $cur_md5 eq $md5 ) {
            &notice( ["error"], "Current twirssi seems to be up to date." );
            return;
        }
    }

    my $URL =
      $settings{upgrade_beta}
      ? "http://github.com/zigdon/twirssi/raw/master/twirssi.pl"
      : "http://twirssi.com/twirssi.pl";
    &notice( ["error"], "Downloading twirssi from $URL" );
    LWP::Simple::getstore( $URL, "$loc.upgrade" );

    unless ( -s "$loc.upgrade" ) {
        &notice( ["error"],
                "Failed to save $loc.upgrade."
              . "  Check that /set twirssi_location is set to the correct location."
        );
        return;
    }

    unless ( $data or $settings{upgrade_beta} ) {
        unless ( open( NEW, "$loc.upgrade" ) ) {
            &notice( ["error"],
                    "Failed to read $loc.upgrade."
                  . "  Check that /set twirssi_location is set to the correct location."
            );
            return;
        }

        my $new_md5 = Digest::MD5::md5_hex(<NEW>);
        close NEW;

        if ( $new_md5 ne $md5 ) {
            &notice( ["error"],
                "MD5 verification failed. expected $md5, got $new_md5" );
            return;
        }
    }

    rename $loc, "$loc.backup"
      or &notice( ["error"], "Failed to back up $loc: $!.  Aborting" )
      and return;
    rename "$loc.upgrade", $loc
      or &notice( ["error"], "Failed to rename $loc.upgrade: $!.  Aborting" )
      and return;

    my ( $dir, $file ) = ( $loc =~ m{(.*)/([^/]+)$} );
    if ( -e "$dir/autorun/$file" ) {
        &notice( ["error"], "Updating $dir/autorun/$file" );
        unlink "$dir/autorun/$file"
          or
          &notice( ["error"], "Failed to remove old $file from autorun: $!" );
        symlink "../$file", "$dir/autorun/$file"
          or &notice( ["error"],
            "Failed to create symlink in autorun directory: $!" );
    }

    &notice( ["error"],
        "Download complete.  Reload twirssi with /script load $file" );
}

sub cmd_list_channels {
    my ( $data, $server, $win ) = @_;

    &notice("Current output channels:");
    foreach my $type ( sort keys %{ $state{__channels} } ) {
        &notice("$type:");
        foreach my $tag ( sort keys %{ $state{__channels}{$type} } ) {
            &notice("  $tag:");
            foreach my $net_tag ( sort keys %{ $state{__channels}{$type}{$tag} } ) {
                &notice("    $net_tag: "
                        . join ', ', @{ $state{__channels}{$type}{$tag}{$net_tag} });
            }
        }
    }
    &notice("Add new entries using /twirssi_set_channel "
          . "[[-]type|*] [account|search_term|*] [net_tag] [channel]" );
    &notice("Type can be one of: tweet, reply, dm, search, error.",
                "A '*' for type/tag indicates wild"
                    . "  (if type is wild, ensure account qualified: [user]\@[service]).",
                "Remove settings by negating type, e.g. '-tweet'.");
}

sub cmd_set_channel {
    my ( $data, $server, $win ) = @_;

    my @words = split ' ', lc $data;
    unless (@words == 4) {
        return &cmd_list_channels(@_);
    }

    my ($type, $tag, $net_tag, $channame) = @words;
    my $delete = 1 if $type =~ s/^-//;

    unless ( $type =~ /^(?:tweet|search|dm|reply|error|\*)$/ ) {
        &notice("ERROR: Invalid message type '$type'.");
        &notice("Valid types: tweet, reply, dm, search, error, *");
        return;
    }

    $tag = &normalize_username($tag) unless $type eq 'search'
            or $type eq '*' or $tag eq '*';

    if ($delete) {
        if (not defined $state{__channels}{$type}
                or not defined $state{__channels}{$type}{$tag}
                or not defined $state{__channels}{$type}{$tag}{$net_tag}
                or not grep { $_ eq $channame } @{ $state{__channels}{$type}{$tag}{$net_tag} }) {
            &notice("No such channel setting for $type/$tag on $net_tag.");
            return;
        }
        &notice("$type/$tag messages will no longer be sent"
              . " to the '$channame' channel on $net_tag" );
        @{ $state{__channels}{$type}{$tag}{$net_tag} } =
            grep { $_ ne $channame } @{ $state{__channels}{$type}{$tag}{$net_tag} };
        delete $state{__channels}{$type}{$tag}{$net_tag}
          unless @{ $state{__channels}{$type}{$tag}{$net_tag} };
        delete $state{__channels}{$type}{$tag}
          unless keys %{ $state{__channels}{$type}{$tag} };
        delete $state{__channels}{$type}
          unless keys %{ $state{__channels}{$type} };

    } elsif (defined $state{__channels}{$type}{$tag}{$net_tag}
                and grep { $_ eq $channame }
                      @{ $state{__channels}{$type}{$tag}{$net_tag} }) {
        &notice("There is already such a channel setting.");
        return;

    } else {
        &notice("$type/$tag messages will now be sent"
              . " to the '$channame' channel on $net_tag" );
        push @{ $state{__channels}{$type}{$tag}{$net_tag} }, $channame;
    }

    &save_state();
    return;
}

sub cmd_list_windows {
    my ( $data, $server, $win ) = @_;

    &notice("Current output windows:");
    foreach my $type ( sort keys %{ $state{__windows} } ) {
        &notice("$type:");
        foreach my $tag ( sort keys %{ $state{__windows}{$type} } ) {
            &notice("  $tag: $state{__windows}{$type}{$tag}");
        }
    }
    &notice( "Default window for all other messages: " . $settings{window} );

    &notice("Add new entries with the /twirssi_set_window "
          . "[type] [tag] [window] command." );
    &notice("Remove a setting by setting window name to '-'.");
}

sub cmd_set_window {
    my ( $data, $server, $win ) = @_;

    my @words = split ' ', $data;

    unless (@words) {
        &cmd_list_windows(@_);
        return;
    }

    my $winname = pop @words;       # the last argument is the window name
    my $delete = $winname eq '-';

    if ( @words == 0 ) {            # just a window name
        $winname = 'twitter' if $delete;
        &notice("Changing the default twirssi window to $winname");
        Irssi::settings_set_str( "twitter_window", $winname );
        &ensure_logfile($settings{window} = $winname);
     } elsif ( @words > 2 ) {
        &notice(
                "Too many arguments to /twirssi_set_window. '@words'",
                "Usage: /twirssi_set_window [type] [account|search_term] [window].",
                "Type can be one of tweet, reply, dm, search, error, default."
        );
        return;
    } elsif ( @words >= 1 ) {
        my $type = lc $words[0];
        unless ( $type =~ /^(?:tweet|search|dm|reply|error|default)$/ ) {
            &notice("ERROR: Invalid message type '$type'.");
            &notice("Valid types: tweet, reply, dm, search, error, default");
            return;
        }

        my $tag = "default";
        if ( @words == 2 ) {
           $tag = lc $words[1];
           if ($type ne 'search' and $type ne 'default' and $tag ne 'default') {
              $tag = &normalize_username($tag);
           }
           if (substr($tag, -1, 1) eq '@') {
              &notice("ERROR: Invalid tag '$tag'.");
              return;
           }
        }

        if ($delete) {
            if (not defined $state{__windows}{$type}
                     or not defined $state{__windows}{$type}{$tag}) {
               &notice("No such window setting for $type/$tag.");
               return;
            }
            &notice("$type/$tag messages will no longer be sent to the '"
                       . $state{__windows}{$type}{$tag} . "' window" );
            delete $state{__windows}{$type}{$tag};
            delete $state{__windows}{$type}
              unless keys %{ $state{__windows}{$type} };
        } else {
            &notice("$type/$tag messages will now"
                  . " be sent to the '$winname' window" );
            $state{__windows}{$type}{$tag} = $winname;
        }

        &save_state();
    }

    &ensure_window($winname) if $winname ne '-';

    return;
}

sub load_friends {
    my $u_twit   = shift;
    my $username = shift;
    my $fh       = shift;
    my $cursor   = -1;
    my $page     = 1;
    my %new_friends;
    eval {
        while ( $page < 11 and $cursor ne "0" )
        {
            &debug($fh, "$username: Loading friends page $page...");
            my $friends;
            if ( ref($u_twit) =~ /^Net::Twitter/ ) {
                $friends = $u_twit->friends( { cursor => $cursor } );
                last unless $friends;
                $cursor  = $friends->{next_cursor};
                $friends = $friends->{users};
            } else {
                $friends = $u_twit->friends( { page => $page } );
                last unless $friends;
            }
            $new_friends{ $_->{screen_name} } = time foreach @$friends;
            $page++;
        }
    };

    if ($@) {
        if ($fh) {
            print $fh "type:debug $username: Error during friends list update.  Aborted.\n";
        } else {
            print "$username: Error during friends list update.  Aborted.";
        }
        return;
    }

    my ( $added, $removed ) = ( 0, 0 );
    # &debug($fh, "$username: Scanning for new friends...");
    foreach ( keys %new_friends ) {
        next if exists $friends{$username}{$_};
        $friends{$username}{$_} = time;
        $added++;
    }

    # &debug($fh, "$username: Scanning for removed friends...");
    foreach ( keys %{ $friends{$username} } ) {
        next if exists $new_friends{$_};
        delete $friends{$username}{$_};
        &debug($fh, "$username: removing friend: $_");
        $removed++;
    }

    return ( $added, $removed );
}

sub load_blocks {
    my $u_twit   = shift;
    my $username = shift;
    my $fh       = shift;
    my %new_blocks;
    eval {
        for my $page (1..10) {
            &debug($fh, "$username: Loading blocks page $page...");
            my $blocks = $u_twit->blocking( { page => $page } );
            last if not defined $blocks or @$blocks == 0
                    or defined $new_blocks{ $blocks->[0]->{screen_name} };
            &debug($fh, "$username: Blocks page $page... " . scalar(@$blocks)
                        . " first block: " . $blocks->[0]->{screen_name});
            $new_blocks{ $_->{screen_name} } = time foreach @$blocks;
        }
    };

    if ($@) {
        if ($fh) {
            print $fh "type:debug $username: Error during blocks list update.  Aborted.\n";
        } else {
            print "Error during blocks list update.  Aborted.";
        }
        return;
    }

    my ( $added, $removed ) = ( 0, 0 );
    # &debug($fh, "$username: Scanning for new blocks...");
    foreach ( keys %new_blocks ) {
        next if exists $blocks{$username}{$_};
        $blocks{$username}{$_} = time;
        $added++;
    }

    # &debug($fh, "$username: Scanning for removed blocks...");
    foreach ( keys %{ $blocks{$username} } ) {
        next if exists $new_blocks{$_};
        delete $blocks{$username}{$_};
        &debug($fh, "$username: removing block: $_");
        $removed++;
    }

    return ( $added, $removed );
}

sub get_reply_to {
    # extract reply-to-information from tweets
    my $t = shift;

    if ($t->{in_reply_to_screen_name}
       and $t->{in_reply_to_status_id}) {
       return sprintf 'reply_to_user:%s reply_to_id:%s ',
           $t->{in_reply_to_screen_name},
           $t->{in_reply_to_status_id};
    } else {
       return '';
    }
}

sub cmd_user {
    my $target = shift;
    $target =~ s/(?::\d+)?\s*$//;
    &debug("cmd_user $target starting");
    return unless &logged_in($twit);
    my $tweets;
    eval { $tweets = $twit->user_timeline({ id => $target, }); };
    if ($@) {
        print "Error during user_timeline $target call: Aborted.";
        &debug("cmd_user: $_\n") foreach split "\n", Dumper($@);
        return;
    }
    my $lines_ref = [];
    my $cache = {};
    my $username = "$user\@$defservice";
    foreach my $t ( reverse @$tweets ) {
        my $t_or_reply = &tweet_or_reply($twit, $t, $username, $cache, undef);
        push @$lines_ref, { &meta_to_line(&tweet_to_meta($twit, $t, $username, $t_or_reply)) };
    }
    &write_lines($lines_ref, 0, 1);

    &debug("cmd_user ends");
}

sub tweet_to_meta {
    my $obj      = shift;
    my $t        = shift;
    my $username = shift;
    my $type     = shift;
    my $topic    = shift;
    my %meta     = (
        username => $username,
        type     => $type,
        nick     => ($type eq 'dm' ? $t->{sender_screen_name}
                                    : ($type =~ /^search/ ? $t->{from_user}
                                                          : $t->{user}{screen_name})),
    );
    ($meta{account}, $meta{service}) = split('@', $username, 2);
    foreach my $meta_key (keys %meta_to_twit) {
        $meta{$meta_key} = $t->{$meta_to_twit{$meta_key}} if defined $t->{$meta_to_twit{$meta_key}};
    }
    $meta{created_at} = &date_to_epoch($meta{created_at});
    $meta{topic} = $topic if defined $topic;
    $meta{text} = &get_text($t, $obj);
    return \%meta;
}

sub tweet_or_reply {
    my $obj      = shift;
    my $t        = shift;
    my $username = shift;
    my $cache    = shift;
    my $fh       = shift;

    my $type = 'tweet';
    if ( $t->{in_reply_to_screen_name}
        and $username !~ /^\Q$t->{in_reply_to_screen_name}\E\@/i
        and not exists $friends{$username}{ $t->{in_reply_to_screen_name} } )
    {
        $nicks{ $t->{in_reply_to_screen_name} } = time;
        unless ( $cache->{ $t->{in_reply_to_status_id} } ) {
            eval {
                $cache->{ $t->{in_reply_to_status_id} } =
                  $obj->show_status( $t->{in_reply_to_status_id} );
            };
        }
        if (my $t_reply = $cache->{ $t->{in_reply_to_status_id} }) {
            if (defined $fh) {
                my $ctext = &get_text( $t_reply, $obj );
                printf $fh "id:%s account:%s %snick:%s type:tweet created_at:%s %s\n",
                  $t_reply->{id}, $username, &get_reply_to($t_reply),
                  $t_reply->{user}{screen_name},
                  &encode_for_file($t_reply->{created_at}),
                  $ctext;
            }
            $type = 'reply';
        }
    }
    return $type;
}

sub get_updates {
    &debug("get_updates starting");

    return unless &logged_in($twit);

    if ($update_is_running) {
        &debug("get_updates aborted: already running");
        return;
    } else {
        $update_is_running = 1;
    }

    my ( $fh, $filename ) = File::Temp::tempfile();
    binmode( $fh, ":" . &get_charset() );
    $child_pid = fork();

    if ($child_pid) {    # parent
        Irssi::timeout_add_once( 5000, 'monitor_child',
            [ "$filename.done", 0 ] );
        Irssi::pidwait_add($child_pid);
    } elsif ( defined $child_pid ) {    # child
        close STDIN;
        close STDOUT;
        close STDERR;

        my $new_poll = time;

        my $error = 0;
        my %context_cache;
        my @to_be_updated = ();
        if ($settings{update_usernames} ne '') {
            foreach my $pref_user (split(',', $settings{update_usernames})) {
                next unless $pref_user = &valid_username($pref_user);
                push @to_be_updated, $pref_user;
            }
        }
        foreach my $other_user (keys %twits) {
            push @to_be_updated, $other_user if not grep { $other_user eq $_ } @to_be_updated;
        }
        foreach ( @to_be_updated ) {
            $error++ unless &do_updates( $fh, $_, $twits{$_}, \%context_cache );

            if ( exists $state{__fixreplies}{$_}
                and keys %{ $state{__fixreplies}{$_} } )
            {
                my @frusers = sort keys %{ $state{__fixreplies}{$_} };

                $error++
                  unless &get_timeline( $fh, $frusers[ $fix_replies_index{$_} ],
                    $_, $twits{$_}, \%context_cache );

                $fix_replies_index{$_}++;
                $fix_replies_index{$_} = 0
                  if $fix_replies_index{$_} >= @frusers;
                print $fh "id:$fix_replies_index{$_} ",
                  "account:$_ type:fix_replies_index\n";
            }
        }

        print $fh "__friends__\n";
        foreach my $username ( @to_be_updated ) {
            print $fh "__friends__\t$username\n";
            if ( time - $last_friends_poll > $settings{friends_poll} ) {
                print $fh "__updated ", time, "\n";
                my ( $added, $removed ) = &load_friends($twits{$username}, $username, $fh);
                if ( $added + $removed ) {
                    print $fh "type:debug %R***%n $username: Friends list updated: ",
                      join( ", ",
                        sprintf( "%d added",   $added ),
                        sprintf( "%d removed", $removed ) ),
                      "\n";
                }
            }

            foreach ( sort keys %{ $friends{$username} } ) {
                print $fh "$_ $friends{$username}{$_}\n";
            }
        }

        print $fh "__blocks__\n";
        foreach my $username ( @to_be_updated ) {
            print $fh "__blocks__\t$username\n";
            if ( time - $last_blocks_poll > $settings{blocks_poll} ) {
                print $fh "__updated ", time, "\n";
                my ( $added, $removed ) = &load_blocks($twits{$username}, $username, $fh);
                if ( $added + $removed ) {
                    print $fh "type:debug %R***%n $username: Blocks list updated: ",
                      join( ", ",
                        sprintf( "%d added",   $added ),
                        sprintf( "%d removed", $removed ) ),
                      "\n";
                }
            }

            foreach ( sort keys %{ $blocks{$username} } ) {
                print $fh "$_ $blocks{$username}{$_}\n";
            }
        }

        if ($error) {
            print $fh "type:debug Update encountered errors.  Aborted\n";
            print $fh "-- $last_poll";
        } else {
            print $fh "-- $new_poll";
        }
        close $fh;
        rename $filename, "$filename.done";
        exit;
    } else {
        &ccrap("Failed to fork for updating: $!");
    }
    &debug("get_updates ends");
}

sub remove_ignored {
    my $text = shift;
    my $ignore_ref = shift;
    my $strip_ref = shift;

    my $text_no_colors = &remove_colors($text);
    foreach my $tag (@$ignore_ref) {
        next unless $text_no_colors =~ /(?:^|\b|\s)\Q$tag\E(?:\b|\s|$)/i;
        $text = (&debug() ? "(ignored: $tag) $text" : '');
        last;
    }

    foreach my $tag ($strip_ref) {
        $text =~ s/\cC\d{2}\Q$tag\E\cO//gi;   # with then without colors
        $text =~ s/(^|\b|\s)\Q$tag\E(\b|\s|$)/$1$2/gi;
    }
    return $text;
}

sub do_updates {
    my ( $fh, $username, $obj, $cache ) = @_;

    eval {
        my $rate_limit = $obj->rate_limit_status();
        if ( $rate_limit and $rate_limit->{remaining_hits} < 1 ) {
            &notice( ["error"], "$username: Rate limit exceeded" );
            return undef;
        }
    };

    &debug($fh, "$username: Polling for updates");
    my $tweets;
    my $new_poll_id      = 0;
    my @ignored_accounts = $settings{ignored_accounts}
      ? split /\s*,\s*/, $settings{ignored_accounts}
      : ();
    eval {
        if ( grep { &normalize_username($_) eq $username } @ignored_accounts )
        {
            $tweets = ();
            &debug($fh, "$username: Ignoring timeline");
        } else {
            if ( $state{__last_id}{$username}{timeline} ) {
                $tweets = $obj->home_timeline( { count => $settings{track_replies} } );
            } else {
                $tweets = $obj->home_timeline();
            }
        }
    };

    if ($@) {
        print $fh "type:debug $username: Error during home_timeline call: Aborted.\n";
        print $fh "type:debug : $_\n" foreach split /\n/, Dumper($@);
        return undef;
    }

    unless ( ref $tweets ) {
        if ( $obj->can("get_error") ) {
            my $error = "Unknown error";
            eval { $error = JSON::Any->jsonToObj( $obj->get_error() ) };
            unless ($@) { $error = $obj->get_error() }
            print $fh
              "type:debug $username: API Error during home_timeline call: Aborted\n";
            print $fh "type:debug : $_\n" foreach split /\n/, Dumper($error);

        } else {
            print $fh
              "type:debug $username: API Error during home_timeline call. Aborted.\n";
        }
        return undef;
    }

    print $fh "type:debug $username got ", scalar(@$tweets), " tweets, first: ",
                        (sort {$a->{id} <=> $b->{id}} @$tweets)[0]->{id}, "\n";

    my @ignore_tags = $settings{ignored_tags}
      ? split /\s*,\s*/, $settings{ignored_tags}
      : ();
    my @strip_tags = $settings{stripped_tags}
      ? split /\s*,\s*/, $settings{stripped_tags}
      : ();
    foreach my $t ( reverse @$tweets ) {
        my $text = &get_text( $t, $obj );
        next if '' eq ($text = &remove_ignored($text, \@ignore_tags, \@strip_tags));
        my $reply = &tweet_or_reply($obj, $t, $username, $cache, $fh);
        next
          if $t->{user}{screen_name} eq $username
              and not $settings{own_tweets};
        printf $fh "id:%s account:%s %snick:%s type:%s created_at:%s %s\n",
          $t->{id}, $username, &get_reply_to($t), $t->{user}{screen_name}, $reply,
          &encode_for_file($t->{created_at}), $text;

        $new_poll_id = $t->{id} if $new_poll_id < $t->{id};
    }
    printf $fh "id:%s account:%s type:last_id timeline\n",
      $new_poll_id, $username;

    &debug($fh, "$username: Polling for replies since " . $state{__last_id}{$username}{reply});
    $new_poll_id = 0;
    eval {
        if ( $state{__last_id}{$username}{reply} )
        {
            $tweets = $obj->replies(
                { since_id => $state{__last_id}{$username}{reply} } )
              || [];
        } else {
            $tweets = $obj->replies() || [];
        }
    };

    if ($@) {
        print $fh "type:debug $username: Error during replies call.  Aborted.\n";
        return undef;
    }

    foreach my $t ( reverse @$tweets ) {
        next
          if exists $friends{$username}{ $t->{user}{screen_name} };

        my $text = &get_text( $t, $obj );
        $new_poll_id = $t->{id} if $new_poll_id < $t->{id};
        next if '' eq ($text = &remove_ignored($text, \@ignore_tags, \@strip_tags));
        printf $fh "id:%s account:%s %snick:%s type:tweet created_at:%s %s\n",
          $t->{id}, $username, &get_reply_to($t), $t->{user}{screen_name},
          &encode_for_file($t->{created_at}), $text;
    }
    printf $fh "id:%s account:%s type:last_id reply\n", $new_poll_id, $username;

    &debug($fh, "$username: Polling for DMs");
    $new_poll_id = 0;
    eval {
        if ( $state{__last_id}{$username}{dm} )
        {
            $tweets = $obj->direct_messages(
                { since_id => $state{__last_id}{$username}{dm} } )
              || [];
        } else {
            $tweets = $obj->direct_messages() || [];
        }
    };

    if ($@) {
        print $fh "type:debug $username: Error during direct_messages call.  Aborted.\n";
        return undef;
    }

    foreach my $t ( reverse @$tweets ) {
        my $text = decode_entities( $t->{text} );
        $text =~ s/[\n\r]/ /g;
        printf $fh "id:%s account:%s %snick:%s type:dm created_at:%s %s\n",
          $t->{id}, $username, &get_reply_to($t), $t->{sender_screen_name},
          &encode_for_file($t->{created_at}), $text;
        $new_poll_id = $t->{id} if $new_poll_id < $t->{id};
    }
    printf $fh "id:%s account:%s type:last_id dm\n", $new_poll_id, $username;

    &debug($fh, "$username: Polling for subscriptions");
    if ( $obj->can('search') and $state{__searches}{$username} ) {
        my $search;
        foreach my $topic ( sort keys %{ $state{__searches}{$username} } ) {
            print $fh "type:debug $username: Search '$topic' id was ",
              "$state{__searches}{$username}{$topic}\n";
            eval {
                $search = $obj->search(
                    {
                        q        => $topic,
                        since_id => $state{__searches}{$username}{$topic}
                    }
                );
            };

            if ($@) {
                print $fh
                  "type:debug $username: Error during search($topic) call.  Aborted.\n";
                return undef;
            }

            unless ( $search->{max_id} ) {
                print $fh "type:debug $username: Invalid search results when searching",
                  " for $topic. Aborted.\n";
                return undef;
            }

            $state{__searches}{$username}{$topic} = $search->{max_id};
            $topic =~ s/ /%20/g;
            printf $fh "id:%s account:%s type:searchid topic:%s\n",
              $search->{max_id}, $username, $topic;

            foreach my $t ( reverse @{ $search->{results} } ) {
                next if exists $blocks{$username}{ $t->{from_user} };
                my $text = &get_text( $t, $obj );
                $new_poll_id = $t->{id}
                  if not $new_poll_id
                      or $t->{id} < $new_poll_id;
                next if '' eq ($text = &remove_ignored($text, \@ignore_tags, \@strip_tags));
                printf $fh "id:%s account:%s nick:%s type:search topic:%s created_at:%s %s\n",
                  $t->{id}, $username, $t->{from_user}, $topic,
                  &encode_for_file($t->{created_at}), $text;
            }
        }
    }

    &debug($fh, "$username: Polling for one-time searches");
    if ( $obj->can('search') and exists $search_once{$username} ) {
        my $search;
        foreach my $topic ( sort keys %{ $search_once{$username} } ) {
            my $max_results = $search_once{$username}->{$topic};

            print $fh
              "type:debug $username: search $topic once (max $max_results)\n";
            eval { $search = $obj->search( { 'q' => $topic } ); };

            if ($@) {
                print $fh
"type:debug $username: Error during search_once($topic) call.  Aborted.\n";
                return undef;
            }

            unless ( $search->{max_id} ) {
                print $fh
                  "type:debug $username: Invalid search results when searching once",
                  " for $topic. Aborted.\n";
                return undef;
            }
            $topic =~ s/ /%20/g;

            # TODO: consider applying ignore-settings to search results
            my @results = ();
            foreach my $res (@{ $search->{results} }) {
                if (exists $blocks{$username}{ $res->{from_user} }) {
                    print $fh "type:debug $username: blocked $topic: $res->{from_user}\n";
                    next;
                }
                push @results, $res;
            }
            if ( $max_results > 0 ) {
                splice @results, $max_results;
            }
            foreach my $t ( reverse @results ) {

                my $text = &get_text( $t, $obj );
                next if '' eq ($text = &remove_ignored($text, \@ignore_tags, \@strip_tags));
                printf $fh
                  "id:%s account:%s %snick:%s type:search_once topic:%s created_at:%s %s\n",
                  $t->{id}, $username, &get_reply_to($t), $t->{from_user}, $topic,
                  &encode_for_file($t->{created_at}), $text;
            }
        }
    }

    &debug($fh, "$username: Done");

    return 1;
}

sub get_timeline {
    my ( $fh, $target, $username, $obj, $cache ) = @_;
    my $tweets;
    my $last_id = $state{__last_id}{$username}{$target};

    print $fh "type:debug $username: get_timeline("
      . "$fix_replies_index{$username}=$target > $last_id) started."
      . "  username = $username\n";
    eval {
        $tweets = $obj->user_timeline(
            {
                id => $target,
                ( $last_id ? ( since_id => $last_id ) : () ),
            }
        );
    };

    if ($@) {
        print $fh
          "type:debug Error $username: during user_timeline($target) call: Aborted.\n";
        print $fh "type:debug : $_\n" foreach split /\n/, Dumper($@);
        return undef;
    }

    unless ($tweets) {
        print $fh
          "type:debug $username: user_timeline($target) call returned undef!  Aborted\n";
        return 1;
    }

    foreach my $t ( reverse @$tweets ) {
        my $text = &get_text( $t, $obj );
        my $reply = &tweet_or_reply($obj, $t, $username, $cache, $fh);
        printf $fh "id:%s account:%s %snick:%s type:%s created_at:%s %s\n",
          $t->{id}, $username, &get_reply_to($t), $t->{user}{screen_name}, $reply,
          &encode_for_file($t->{created_at}), $text;
        $last_id = $t->{id} if $last_id < $t->{id};
    }
    printf $fh "id:%s account:%s type:last_id_fixreplies %s\n",
      $last_id, $username, $target;

    return 1;
}

sub encode_for_file {
    my $datum = shift;
    $datum =~ s/ /%20/g;
    return $datum;
}

sub date_to_epoch {
    # parse created_at style date to epoch time
    my $date = shift;
    if (not @datetime_parser) {
	foreach my $date_fmt (
			'%a %b %d %T %z %Y',	# Fri Nov 05 10:14:05 +0000 2010
			'%a, %d %b %Y %T %z',	# Fri, 05 Nov 2010 16:59:40 +0000
		) {
            my $parser = DateTime::Format::Strptime->new(pattern => $date_fmt);
            if (not defined $parser) {
                @datetime_parser = ();
                return;
            }
            push @datetime_parser, $parser;
        }
    }
    # my $orig_date = $date;
    $date = $datetime_parser[index($date, ',') == -1 ? 0 : 1]->parse_datetime($date);
    # &debug("date '$orig_date': " . ref($date));
    return if not defined $date;
    return $date->epoch();
}

sub meta_to_line {
    my $meta = shift;
    my %line_attribs = (
            username => $meta->{username}, epoch   => $meta->{created_at},
            type     => $meta->{type},     account => $meta->{account},
            service  => $meta->{service},  nick    => $meta->{nick},
            hilight  => 0,                 hi_nick => $meta->{nick},
            text     => $meta->{text},     topic   => $meta->{topic},
            level    => MSGLEVEL_PUBLIC,
    );

    if ($meta->{type} eq 'dm' or $meta->{type} eq 'error') {
        $line_attribs{level} = MSGLEVEL_MSGS;
    }

    my $nick = "\@$meta->{account}";
    if ( $meta->{text} =~ /\Q$nick\E(?:\W|$)/i ) {
        my $hilight_color        = $irssi_to_mirc_colors{ $settings{hilight_color} };
        $line_attribs{level}  |= MSGLEVEL_HILIGHT;
        $line_attribs{hi_nick} = "\cC$hilight_color$meta->{nick}\cO";
    }

    if ( $meta->{type} ne 'dm' and $meta->{nick} and $meta->{id} ) {
        my $marker;
        for (my $mark_idx = 0;
                defined $state{__ids}{ lc $meta->{nick} }
                  and $mark_idx < @{ $state{__ids}{ lc $meta->{nick} } };
                $mark_idx++) {
            if ($state{__ids}{ lc $meta->{nick} }[$mark_idx] eq $meta->{id}) {
                $marker = $mark_idx;
                last;
            }
        }
        if (not defined $marker) {
            $marker = ( $state{__indexes}{ lc $meta->{nick} } + 1 ) % $settings{track_replies};
            $state{__ids}{ lc $meta->{nick} }[$marker]    = $meta->{id};
            $state{__indexes}{ lc $meta->{nick} }         = $marker;
            $state{__tweets}{ lc $meta->{nick} }[$marker] = $meta->{text};
            foreach my $key (qw/username reply_to_id reply_to_user created_at/) {
                $state{"__${key}s"}{ lc $meta->{nick} }[$marker] = $meta->{$key};
            }
        }
        $line_attribs{marker} = ":$marker";
    }
    return %line_attribs;
}

sub monitor_child {
    my ($data)   = @_;
    my $filename = $data->[0];
    my $attempt  = $data->[1];

    &debug("checking child log at $filename ($attempt)");
    my ($new_last_poll);

    # reap any random leftover processes - work around a bug in irssi on gentoo
    waitpid( -1, WNOHANG );

    # first time we run we don't want to print out *everything*, so we just
    # pretend

    if ( open FILE, $filename ) {
        binmode FILE, ":" . &get_charset();
        my @lines;
        my %new_cache;
        while (<FILE>) {
            last if /^__friends__/;
            unless (/\n$/) {    # skip partial lines
                # &debug("Skipping partial line: $_");
                next;
            }
            chomp;
            my %meta;

            foreach my $key (qw/id account reply_to_user reply_to_id nick type topic created_at/) {
                if (s/^$key:((?:\S|\\ )+)\s*//) {
                    $meta{$key} = $1;
                    $meta{$key} =~ s/%20/ /g;
                }
            }

            if ( $meta{type} and $meta{type} eq 'fix_replies_index' ) {
                $fix_replies_index{ $meta{account} } = $meta{id};
                &debug("$meta{account}: fix_replies_index set to $meta{id}");
                next;
            }

            if ( not $meta{type} or $meta{type} !~ /searchid|last_id/ ) {
                if ( exists $meta{id} and exists $new_cache{ $meta{id} } ) {
                    next;
                }

                $new_cache{ $meta{id} } = time;

                if ( exists $meta{id} and exists $tweet_cache{ $meta{id} } ) {
                    next;
                }
            }

            $meta{username} = &normalize_username($meta{account});	# username is account@Service
            $meta{account} =~ s/\@(\w+)$//;
            $meta{service} = $1;
            $meta{created_at} = &date_to_epoch($meta{created_at});
            $meta{text} = $_;

            my %line_attribs = &meta_to_line(\%meta);

            if ( $meta{type} =~ /tweet|reply/
                    or $meta{type} eq 'dm'
                    or $meta{type} eq 'error' ) {
                push @lines, { %line_attribs };
            } elsif ( $meta{type} eq 'search' ) {
                push @lines, { %line_attribs };
                if ( exists $state{__searches}{ $meta{username} }{ $meta{topic} }
                    and $meta{id} >
                    $state{__searches}{ $meta{username} }{ $meta{topic} } )
                {
                    $state{__searches}{ $meta{username} }{ $meta{topic} } =
                      $meta{id};
                }
            } elsif ( $meta{type} eq 'search_once' ) {
                push @lines, { %line_attribs };
                delete $search_once{ $meta{username} }->{ $meta{topic} };
            } elsif ( $meta{type} eq 'searchid' ) {
                &debug("$meta{username}: Search '$meta{topic}' got id $meta{id}");
                if (
                    not
                    exists $state{__searches}{ $meta{username} }{ $meta{topic} }
                    or $meta{id} >=
                    $state{__searches}{ $meta{username} }{ $meta{topic} } )
                {
                    $state{__searches}{ $meta{username} }{ $meta{topic} } =
                      $meta{id};
                } else {
                    &debug("$meta{username}: Search '$meta{topic}' bad id $meta{id}");
                }
            } elsif ( $meta{type} eq 'last_id' ) {
                $state{__last_id}{ $meta{username} }{$_} =
                  $meta{id}
                  if $state{__last_id}{ $meta{username} }{$_} <
                      $meta{id};
            } elsif ( $meta{type} eq 'last_id_fixreplies' ) {
                $state{__last_id}{ $meta{username} }{$_} =
                  $meta{id}
                  if $state{__last_id}{ $meta{username} }{$_} <
                      $meta{id};
            } elsif ( $meta{type} eq 'debug' ) {
                &debug($_);
            } else {
                &debug("Unknown line type $meta{type}: $_");
            }
        }

        %friends = ();
        my $username;
        while (<FILE>) {
            if (/^__friends__\t(.+)$/) {
                $username = $1;
                next;
            } elsif (/^__blocks__$/) {
                last;
            } elsif (/^__updated (\d+)$/) {
                $last_friends_poll = $1;
                &debug("$username: Friends list updated");
                next;
            } elsif (s/^type:debug\s+//) {
                chomp;
                &debug($_);
                next;
            }
            my ( $f, $t ) = split ' ', $_;
            $nicks{$f} = $friends{$username}{$f} = $t;
        }

        %blocks = ();
        while (<FILE>) {
            if (/^__blocks__\t(.+)$/) {
                $username = $1;
                next;
            } elsif (/^__updated (\d+)$/) {
                $last_blocks_poll = $1;
                &debug("$username: Block list updated");
                next;
            } elsif (s/^type:debug\s+//) {
                chomp;
                &debug($_);
                next;
            } elsif (/^-- (\d+)$/) {
                $new_last_poll = $1;
                if ( $new_last_poll >= $last_poll ) {
                    last;
                } else {
                    &debug("$username: Impossible!  "
                      . "new_last_poll=$new_last_poll < last_poll=$last_poll!");
                    undef $new_last_poll;
                    next;
                }
            }
            my ( $b, $t ) = split ' ', $_;
            $blocks{$username}{$b} = $t;
        }

        if ($new_last_poll) {
            &debug("new last_poll    = $new_last_poll",
                   "new last_poll_id = " . Dumper( $state{__last_id} ));
            if ($first_call) {
                &debug("First call, not printing updates");
            } else {
                &write_lines(\@lines, 1);
            }

            close FILE;
            unlink $filename
              or warn "Failed to remove $filename: $!"
              unless &debug();

            # commit the pending cache lines to the actual cache, now that
            # we've printed our output
            %tweet_cache = ( %tweet_cache, %new_cache );

            # keep enough cached tweets, to make sure we don't show duplicates.
            foreach ( keys %tweet_cache ) {
                next if $tweet_cache{$_} >= $last_poll - 3600;
                delete $tweet_cache{$_};
            }
            $last_poll = $new_last_poll;

            # make sure the pid is removed from the waitpid list
            Irssi::pidwait_remove($child_pid);

            # and that we don't leave any zombies behind, somehow
            waitpid( -1, WNOHANG );

            &save_state();
            $failstatus        = 0;
            $first_call        = 0;
            $update_is_running = 0;
            return;
        }
    }

    close FILE;

    if ( $attempt < 24 ) {
        Irssi::timeout_add_once( 5000, 'monitor_child',
            [ $filename, $attempt + 1 ] );
    } else {
        &debug("Giving up on polling $filename");
        Irssi::pidwait_remove($child_pid);
        waitpid( -1, WNOHANG );
        unlink $filename unless &debug();

        $update_is_running = 0;

        return unless $settings{notify_timeouts};

        my $since;
        my @time = localtime($last_poll);
        if ( time - $last_poll < 24 * 60 * 60 ) {
            $since = sprintf( "%d:%02d", @time[ 2, 1 ] );
        } else {
            $since = scalar localtime($last_poll);
        }

        if ( $failstatus < 2 and time - $last_poll > 60 * 60 ) {
            &ccrap(
              $settings{mini_whale}
              ? 'FAIL WHALE'
              : q{     v  v        v},
                q{     |  |  v     |  v},
                q{     | .-, |     |  |},
                q{  .--./ /  |  _.---.| },
                q{   '-. (__..-"       \\},
                q{      \\          a    |},
                q{       ',.__.   ,__.-'/},
                q{         '--/_.'----'`}
            );
            $failstatus = 2;
        }

        if ( $failstatus == 0 and time - $last_poll < 600 ) {
            &ccrap("Haven't been able to get updated tweets since $since");
            $failstatus = 1;
        }
    }
}

sub write_lines {
    my $lines_ref       = shift;
    my $want_extras     = shift;
    my $want_ymd_suffix = shift;
    my $old_tf = Irssi::settings_get_str('timestamp_format');
    my $ymd_color = $irssi_to_mirc_colors{ $settings{ymd_color} };
    my @date_now = localtime();
    my $ymd_now = sprintf('%04d-%02d-%02d', $date_now[5]+1900, $date_now[4]+1, $date_now[3]);
    foreach my $line (@$lines_ref) {
       my $win_name = &window( $line->{type}, $line->{username}, $line->{topic} );
       my $ac_tag = '';
       if ( lc $line->{service} ne lc $settings{default_service} ) {
            $ac_tag = "$line->{username}: ";
        } elsif ( $line->{username} ne "$user\@$defservice"
                and lc $line->{account} ne lc $win_name ) {
            $ac_tag = $line->{account} . ': ';
        }

        my @print_opts = (
            $line->{level},
            "twirssi_" . $line->{type},
            $ac_tag,
        );
        push @print_opts, (lc $line->{topic} ne lc $win_name ? $line->{topic} . ':' : '')
          if $line->{type} =~ /search/;
        push @print_opts, $line->{hi_nick} if $line->{type} ne 'error';
        push @print_opts, $line->{marker} if defined $line->{marker};

        # set timestamp
        my @date = localtime($line->{epoch});
        my $ymd  = sprintf('%04d-%02d-%02d', $date[5]+1900, $date[4]+1, $date[3]);
        my $ymd_suffix = '';
        if ($want_ymd_suffix) {
            $ymd_suffix = " \cC$ymd_color$ymd\cO" if $ymd_now ne $ymd;
        } elsif (not defined $last_ymd{wins}{$win_name}
            or $last_ymd{wins}{$win_name}->{ymd}
                  ne (my $ymd = sprintf('%04d-%02d-%02d', $date[5]+1900, $date[4]+1, $date[3]))) {
            Irssi::window_find_name($win_name)->printformat(MSGLEVEL_PUBLIC, 'twirssi_new_day', $ymd, '');
            $last_ymd{wins}{$win_name}->{ymd} = $ymd;
        }
        my $ts = DateTime->from_epoch( epoch => $line->{epoch}, time_zone => $local_tz
                                                    )->strftime($settings{timestamp_format});
        Irssi::settings_set_str('timestamp_format', $ts);
        Irssi::window_find_name($win_name)->printformat(
            @print_opts, &hilight( $line->{text} ) . $ymd_suffix
        );
        if ($want_extras) {
            &write_log($line, $win_name, \@date);
            &write_channels($line, \@date);
        }
    }
    # recall timestamp format
    Irssi::settings_set_str('timestamp_format', $old_tf);
}

sub write_channels {
    my $line = shift;
    my $date_ref = shift;
    my %msg_seen;
    for my $type ($line->{type}, '*') {
        next unless defined $state{__channels}{$type};
        for my $tag (($line->{type} =~ /search/ ? $line->{topic}
                                                : $line->{username}),
                          '*') {
            next unless defined $state{__channels}{$type}{$tag};
            for my $net_tag (keys %{ $state{__channels}{$type}{$tag} }) {
                for my $channame (@{ $state{__channels}{$type}{$tag}{$net_tag} }) {
                    next if defined $msg_seen{$net_tag}{$channame};
                    my $server = Irssi::server_find_tag($net_tag);
                    $last_ymd{chans}{$channame} = {} if not defined $last_ymd{chans}{$channame};
                    for my $log_line (&log_format($line, $channame, $last_ymd{chans}{$channame}, $date_ref)) {
                        if (defined $server) {
                            $server->command("msg -$net_tag $channame $log_line");
                            $msg_seen{$net_tag}{$channame} = 1;
                        } else {
                            &notice("no server for $net_tag/$channame: $log_line");
                        }
                    }
                }
            }
        }
    }
}

sub write_log {
    my $line = shift;
    my $win_name = shift;
    my $date_ref = shift;
    return unless my $logfile_obj = &ensure_logfile($win_name);
    my $fh = $logfile_obj->{fh};
    for my $log_line (&log_format($line, $logfile_obj->{filename}, $logfile_obj, $date_ref, 1)) {
        print $fh $log_line, "\n";
    }
}

sub log_format {
    my $line = shift;
    my $target_name = shift;
    my $ymd_obj = shift;        # can be $last_ymd{chans}{$chan} or $logfile_obj (both need to have ->{ymd})
    my $date_ref = shift;
    my $to_file = shift;

    my @logs = ();

    my $ymd = sprintf('%04d-%02d-%02d', $date_ref->[5]+1900, $date_ref->[4]+1, $date_ref->[3]);
    if ($ymd_obj->{ymd} ne $ymd) {
        push @logs, "Day changed to $ymd";
        $ymd_obj->{ymd} = $ymd;
    }

    my $out = '';
    $out .= sprintf('%02d:%02d:%02d ', $date_ref->[2], $date_ref->[1], $date_ref->[0]) if $to_file;
    if ( $line->{type} eq 'dm' ) {
        $out .= 'DM @' . $line->{hi_nick} . ':';
    } elsif ( $line->{type} eq 'search' or $line->{type} eq 'search_once' ) {
        $out .= '[' . ($target_name =~ /$line->{topic}/ ? '' : "$line->{topic}:")
                . '@' . $line->{hi_nick} . ']';
    } elsif ( $line->{type} eq 'tweet' or $line->{type} eq 'reply' ) {
        $out .= '<' . ($target_name =~ /$line->{account}/ ? '' : "$line->{account}:")
                . '@' . $line->{hi_nick} . '>';
    } else {
        $out .= 'ERR:';
    }
    push @logs, $out . ' ' . ($to_file ? &remove_colors($line->{text}) : $line->{text});
    return @logs;
}

sub remove_colors {
    my $txt = shift;
    $txt =~ s/\cC\d{2}(.*?)\cO/$1/g;
    return $txt;
}

sub save_state {

    # save state hash
    if ( keys %state and my $file = $settings{replies_store} ) {
        if ( open JSON, ">$file" ) {
            print JSON JSON::Any->objToJson( \%state );
            close JSON;
        } else {
            &ccrap("Failed to write state to $file: $!");
        }
    }
}

sub debug {
    return if not $settings{debug};
    my $fh;
    $fh = shift if ref($_[0]) eq 'GLOB';
    while (@_) {
        my $line = shift;
        next if not defined $line;
        chomp $line;
        for my $sub_line (split("\n", $line)) {
            next if $sub_line eq '';
            if ($fh) {
                print $fh 'type:debug ', $sub_line, "\n";
            } else {
                print '[twirssi] ', $sub_line;
            }
        }
    }
    return 1;
}

sub notice {
    my ( $type, $tag );
    if ( ref $_[0] ) {
        ( $type, $tag ) = @{ shift @_ };
    }
    foreach my $msg (@_) {
        Irssi::window_find_name(&window( $type, $tag ))->print(
            "%R***%n $msg", MSGLEVEL_PUBLIC );
    }
}

sub ccrap {
    foreach my $msg (@_) {
        Irssi::window_find_name(&window())->print(
            "%R***%n $msg", MSGLEVEL_CLIENTCRAP );
    }
}

sub update_away {
    my $data = shift;

    if (    $settings{to_away}
        and $data !~ /\@\w/
        and $data !~ /^[dD] / )
    {
        my $server = Irssi::server_find_tag( $settings{bitlbee_server} );
        if ($server) {
            $server->send_raw("away :$data");
            return 1;
        } else {
            &ccrap( "Can't find bitlbee server.",
                "Update bitlbee_server or disable tweet_to_away" );
            return 0;
        }
    }

    return 0;
}

sub too_long {
    my $data    = shift;
    my $noalert = shift;

    if ( length $data > 140 ) {
        &notice( ["tweet"],
            "Tweet too long (" . length($data) . " characters) - aborted" )
          unless $noalert;
        return 1;
    }

    return 0;
}

sub make_utf8 {
    my $data = shift;
    if ( !utf8::is_utf8($data) ) {
        return decode &get_charset(), $data;
    } else {
        return $data;
    }
}

sub valid_username {
    my $username = shift;

    $username = &normalize_username($username);

    unless ( exists $twits{$username} ) {
        &notice( ["error"], "Unknown username $username" );
        return undef;
    }

    return $username;
}

sub logged_in {
    my $obj = shift;
    unless ($obj) {
        &notice( ["error"],
            "Not logged in!  Use /twitter_login username pass!" );
        return 0;
    }

    return 1;
}

sub sig_complete {
    my ( $complist, $window, $word, $linestart, $want_space ) = @_;

    if (
        $linestart =~
        m{^/twitter_delete\s*$|^/(?:retweet|twitter_info|twitter_reply)(?:_as)?\s*$}
        or (    $settings{use_reply_aliases}
            and $linestart =~ /^\/reply(?:_as)?\s*$/ )
      )
    {    # /twitter_reply gets a nick:num
        $word =~ s/^@//;
        @$complist = map { "$_:$state{__indexes}{lc $_}" }
          sort { $nicks{$b} <=> $nicks{$a} }
          grep /^\Q$word/i,
          keys %{ $state{__indexes} };
    }

    if ( $linestart =~
/^\/twitter_(?:unfriend|add_follow_extra|del_follow_extra|spam|block|user)\s*$/
      )
    {    # /twitter_unfriend gets a nick
        $word =~ s/^@//;
        push @$complist, grep /^\Q$word/i,
          sort { $nicks{$b} <=> $nicks{$a} } keys %nicks;
    }

    # /tweet, /tweet_as, /dm, /dm_as - complete @nicks (and nicks as the first
    # arg to dm)
    if ( $linestart =~ /^\/(?:tweet|dm)/ ) {
        my $prefix = $word =~ s/^@//;
        $prefix = 0 if $linestart eq '/dm' or $linestart eq '/dm_as';
        push @$complist, grep /^\Q$word/i,
          sort { $nicks{$b} <=> $nicks{$a} } keys %nicks;
        @$complist = map { "\@$_" } @$complist if $prefix;
    }
}

sub event_send_text {
    my ( $line, $server, $win ) = @_;
    my $awin = Irssi::active_win();

    # if the window where we got our text was the twitter window, and the user
    # wants to be lazy, tweet away!
    my $acc = &window_to_account( $awin->get_active_name() );
    if ( $acc and $settings{window_input} ) {
        &cmd_tweet_as( "$acc $line", $server, $win );
    }
}

sub event_setup_changed {
    foreach (
        qw/
        broadcast_users
        charset
        default_service
        ignored_accounts
        ignored_tags
        location
        nick_color
        ymd_color
        oauth_store
        replies_store
        retweet_format
        stripped_tags
        topic_color
        timestamp_format
        /
      )
    {
        $settings{$_} = Irssi::settings_get_str("twirssi_$_");
    }

    foreach (
        [ 'always_shorten',    'twirssi_always_shorten' ],
        [ 'avoid_ssl',         'twirssi_avoid_ssl' ],
        [ 'debug',             'twirssi_debug' ],
        [ 'notify_timeouts',   'twirssi_notify_timeouts' ],
        [ 'logging',           'twirssi_logging' ],
        [ 'mini_whale',        'twirssi_mini_whale' ],
        [ 'own_tweets',        'show_own_tweets' ],
        [ 'to_away',           'tweet_to_away' ],
        [ 'upgrade_beta',      'twirssi_upgrade_beta' ],
        [ 'use_oauth',         'twirssi_use_oauth' ],
        [ 'use_reply_aliases', 'twirssi_use_reply_aliases' ],
        [ 'window_input',      'tweet_window_input' ],
      )
    {
        $settings{ $_->[0] } = Irssi::settings_get_bool( $_->[1] );
    }

    $settings{friends_poll}  = Irssi::settings_get_int("twitter_friends_poll");
    $settings{poll_interval} = Irssi::settings_get_int("twitter_poll_interval");
    $settings{poll_schedule} = Irssi::settings_get_str("twitter_poll_schedule");
    $settings{search_results} =
      Irssi::settings_get_int("twitter_search_results");
    $settings{timeout} = Irssi::settings_get_int("twitter_timeout");
    $settings{track_replies} = Irssi::settings_get_int("twirssi_track_replies");

    $settings{bitlbee_server} = Irssi::settings_get_str("bitlbee_server");
    $settings{hilight_color}  = Irssi::settings_get_str("hilight_color");
    $settings{passwords}      = Irssi::settings_get_str("twitter_passwords");
    $settings{usernames}      = Irssi::settings_get_str("twitter_usernames");
    $settings{update_usernames} = Irssi::settings_get_str("twitter_update_usernames");
    $settings{url_provider}   = Irssi::settings_get_str("short_url_provider");
    $settings{url_args}       = Irssi::settings_get_str("short_url_args");
    $settings{window}         = Irssi::settings_get_str("twitter_window");

    &ensure_logfile($settings{window});

    &debug("Settings changed:" . Dumper \%settings);
}

sub ensure_logfile() {
    my $win_name = shift;
    return unless $settings{logging};
    my $new_logfile = Irssi::settings_get_str('autolog_path');
    return if $new_logfile eq '';
    $new_logfile =~ s/^~/$ENV{HOME}/;
    $new_logfile = strftime($new_logfile, localtime());
    $new_logfile =~ s/\$(tag\b|\{tag\})/twirssi/g;
    if ($new_logfile !~ s/\$(0\b|\{0\})/$win_name/g) {
        # not per-window logging, so use default window name as key
        $win_name = $settings{window};
    }
    return $logfile{$win_name} if defined $logfile{$win_name} and $new_logfile eq $logfile{$win_name}->{filename};
    return if not &ensure_dir_for($new_logfile);
    my $old_umask = umask(0177);
    &debug("Logging to $new_logfile");
    my $res;
    if ( my $fh = FileHandle->new( $new_logfile, '>>' ) ) {
        umask($old_umask);
        binmode $fh, ':utf8';
        $fh->autoflush(1);
        $res = $logfile{$win_name} = {
		'fh' => $fh,
        	'filename' => $new_logfile,
                'ymd' => '',
	};
    } else {
        &notice( ["error"],
            "ERROR: Failed to append to $new_logfile: $!" );
    }
    umask($old_umask);
    return $res;
}

sub ensure_dir_for {
    my $path = shift;
    if (not $path =~ s@/[^/]+$@@) {
        &debug("Cannot cd up $path");
        return;
    }
    return 1 if $path eq '' or -d $path or $path eq '/';
    return if not &ensure_dir_for($path);
    if (not mkdir($path, 0700)) {
        &debug("Cannot make $path: $!");
        return;
    }
    return 1;
}

sub get_poll_time {
    my $poll = $settings{poll_interval};
    my $algo = $settings{poll_schedule};
    if ( $algo ne '' ) {
        my $hhmm = sprintf('%02d%02d', (localtime())[2,1]);
        foreach my $tuple ( split(',', $algo) ) {
            if ( $tuple =~ /^(\d{4})-(\d{4}):(\d+)$/ ) {
                my($range_from, $range_to, $poll_val) = ($1, $2, $3);
                if ( ( $hhmm ge $range_from and $hhmm lt $range_to )
                    or ( $range_from gt $range_to
                        and ( $hhmm ge $range_from or $hhmm lt $range_to ) )
                   ) {
                    $poll = $poll_val;
                }
            }
        }
    }
    return $poll if $poll >= 60;
    return 60;
}

sub get_charset {
    my $charset = $settings{charset};
    return "utf8" if $charset =~ /^\s*$/;
    return $charset;
}

sub hilight {
    my $text = shift;

    if ( $settings{nick_color} ) {
        my $c = $settings{nick_color};
        $c = $irssi_to_mirc_colors{$c};
        $text =~ s/(^|\W)\@(\w+)/$1\cC$c\@$2\cO/g if $c;
    }
    if ( $settings{topic_color} ) {
        my $c = $settings{topic_color};
        $c = $irssi_to_mirc_colors{$c};
        $text =~ s/(^|\W)(\#|\!)([-\w]+)/$1\cC$c$2$3\cO/g if $c;
    }
    $text =~ s/[\n\r]/ /g;

    return $text;
}

sub shorten {
    my $data = shift;

    my $provider = $settings{url_provider};
    if ( ( $settings{always_shorten} or &too_long( $data, 1 ) ) and $provider )
    {
        my @args;
        if ( $provider eq 'Bitly' ) {
            @args[ 1, 2 ] = split ',', $settings{url_args}, 2;
            unless ( @args == 3 ) {
                &ccrap(
                    "WWW::Shorten::Bitly requires a username and API key.",
                    "Set short_url_args to username,API_key or change your",
                    "short_url_provider."
                );
                $data = &make_utf8($data);
                return $data;
            }
        }

        foreach my $url ( $data =~ /(https?:\/\/\S+[\w\/])/g ) {
            eval {
                $args[0] = $url;
                my $short = makeashorterlink(@args);
                if ($short) {
                    $data =~ s/\Q$url/$short/g;
                } else {
                    &notice( ["error"], "Failed to shorten $url!" );
                }
            };
        }
    }

    $data = &make_utf8($data);
    return $data;
}

sub normalize_username {
    my $user = shift;
    return '' if $user eq '';

    my ( $username, $service ) = split /\@/, lc($user), 2;
    if ($service) {
        $service = ucfirst $service;
    } else {
        $service = ucfirst lc $settings{default_service};
        unless ( exists $twits{"$username\@$service"} ) {
            $service = undef;
            foreach my $t ( sort keys %twits ) {
                next unless $t =~ /^\Q$username\E\@(Twitter|Identica)/;
                $service = $1;
                last;
            }

            unless ($service) {
                &notice( ["error"], "Can't find a logged in user '$user'" );
                return "$username\@$settings{default_service}";
            }
        }
    }

    return "$username\@$service";
}

sub get_text {
    my $tweet  = shift;
    my $object = shift;
    my $text   = decode_entities( $tweet->{text} );
    if ( $tweet->{truncated} ) {
        if ( exists $tweet->{retweeted_status} ) {
            $text = "RT \@$tweet->{retweeted_status}{user}{screen_name}: "
              . "$tweet->{retweeted_status}{text}";
        } elsif ( $object->isa('Net::Twitter') ) {
            $text .= " -- http://twitter.com/$tweet->{user}{screen_name}"
              . "/status/$tweet->{id}";
        }
    }

    $text =~ s/[\n\r]/ /g;

    return $text;
}

sub window {
    my $type  = shift || "default";
    my $uname = shift || "default";
    my $topic = lc(shift || '');

    $type = "search" if $type eq 'search_once';

    my $win;
    for my $type_iter ($type, 'default') {
        next unless exists $state{__windows}{$type_iter};
        $win =
             $state{__windows}{$type_iter}{$uname}
          || $state{__windows}{$type_iter}{$topic}
          || $state{__windows}{$type_iter}{$user}
          || $state{__windows}{$type_iter}{default};
        last if defined $win or $type_iter eq 'default';
    }
    $win = $settings{window} if not defined $win;
    if (not &ensure_window($win)) {
        $win = $settings{window};
    }

    # &debug("window($type, $uname, $topic) -> $win");
    return $win;
}

sub ensure_window {
    my $win = shift;
    return $win if Irssi::window_find_name($win);
    Irssi::active_win()->print("Creating window '$win'.");
    #   &notice("Creating a new window: '$winname'");
    my $newwin = Irssi::Windowitem::window_create( $win, 1 );
    if (not $newwin) {
        Irssi::active_win()->print("Failed to create window $win!");
        return;
    }
    $newwin->set_name($win);
    return $win;
}

sub window_to_account {
    my $name = shift;

    foreach my $type ( keys %{ $state{__windows} } ) {
        foreach my $uname ( keys %{ $state{__windows}{$type} } ) {
            if ( lc $state{__windows}{$type}{$uname} eq lc $name ) {
                return $uname;
            }
        }
    }

    if ( lc $name eq $settings{window} ) {
        return $user;
    }

    return undef;
}

Irssi::signal_add( "send text",     "event_send_text" );
Irssi::signal_add( "setup changed", "event_setup_changed" );

Irssi::theme_register(
    [
        'twirssi_tweet',       '[$0%B@$1%n$2] $3',
        'twirssi_search',      '[$0%r$1%n%B@$2%n$3] $4',
        'twirssi_search_once', '[$0%r$1%n%B@$2%n$3] $4',
        'twirssi_reply',       '[$0\--> %B@$1%n$2] $3',
        'twirssi_dm',          '[$0%r@$1%n (%WDM%n)] $2',
        'twirssi_error',       'ERROR: $0',
        'twirssi_new_day',     'Day changed to $0',
    ]
);

Irssi::settings_add_str( "twirssi", "twitter_poll_schedule",    "" );
Irssi::settings_add_str( "twirssi", "twirssi_charset",          "utf8" );
Irssi::settings_add_str( "twirssi", "twitter_window",           "twitter" );
Irssi::settings_add_str( "twirssi", "bitlbee_server",           "bitlbee" );
Irssi::settings_add_str( "twirssi", "short_url_provider",       "TinyURL" );
Irssi::settings_add_str( "twirssi", "short_url_args",           undef );
Irssi::settings_add_str( "twirssi", "twitter_usernames",        undef );
Irssi::settings_add_str( "twirssi", "twitter_update_usernames", undef );
Irssi::settings_add_str( "twirssi", "twitter_passwords",        undef );
Irssi::settings_add_str( "twirssi", "twirssi_broadcast_users",  undef );
Irssi::settings_add_str( "twirssi", "twirssi_default_service",  "Twitter" );
Irssi::settings_add_str( "twirssi", "twirssi_nick_color",       "%B" );
Irssi::settings_add_str( "twirssi", "twirssi_topic_color",      "%r" );
Irssi::settings_add_str( "twirssi", "twirssi_ymd_color",        "%r" );
Irssi::settings_add_str( "twirssi", "twirssi_timestamp_format", "%H:%M:%S" );
Irssi::settings_add_str( "twirssi", "twirssi_ignored_tags",     "" );
Irssi::settings_add_str( "twirssi", "twirssi_stripped_tags",    "" );
Irssi::settings_add_str( "twirssi", "twirssi_ignored_accounts", "" );
Irssi::settings_add_str( "twirssi", "twirssi_retweet_format",
    'RT $n: "$t" ${-- $c$}' );
Irssi::settings_add_str( "twirssi", "twirssi_location",
    Irssi::get_irssi_dir . "/scripts/twirssi.pl" );
Irssi::settings_add_str( "twirssi", "twirssi_replies_store",
    Irssi::get_irssi_dir . "/scripts/twirssi.json" );
Irssi::settings_add_str( "twirssi", "twirssi_oauth_store",
    Irssi::get_irssi_dir . "/scripts/twirssi.oauth" );

Irssi::settings_add_int( "twirssi", "twitter_poll_interval", 300 );
Irssi::settings_add_int( "twirssi", "twitter_friends_poll",   600 );
Irssi::settings_add_int( "twirssi", "twitter_timeout",        30 );
Irssi::settings_add_int( "twirssi", "twitter_search_results", 5 );
Irssi::settings_add_int( "twirssi", "twirssi_track_replies",  100 );

Irssi::settings_add_bool( "twirssi", "twirssi_upgrade_beta",      0 );
Irssi::settings_add_bool( "twirssi", "tweet_to_away",             0 );
Irssi::settings_add_bool( "twirssi", "show_own_tweets",           1 );
Irssi::settings_add_bool( "twirssi", "twirssi_debug",             0 );
Irssi::settings_add_bool( "twirssi", "twirssi_use_reply_aliases", 0 );
Irssi::settings_add_bool( "twirssi", "twirssi_notify_timeouts",   1 );
Irssi::settings_add_bool( "twirssi", "twirssi_always_shorten",    0 );
Irssi::settings_add_bool( "twirssi", "tweet_window_input",        0 );
Irssi::settings_add_bool( "twirssi", "twirssi_avoid_ssl",         0 );
Irssi::settings_add_bool( "twirssi", "twirssi_use_oauth",         1 );
Irssi::settings_add_bool( "twirssi", "twirssi_logging",           0 );
Irssi::settings_add_bool( "twirssi", "twirssi_mini_whale",        0 );

$last_poll = time - &get_poll_time;

&event_setup_changed();
if ( Irssi::window_find_name(window()) ) {
    Irssi::command_bind( "dm",                         "cmd_direct" );
    Irssi::command_bind( "dm_as",                      "cmd_direct_as" );
    Irssi::command_bind( "tweet",                      "cmd_tweet" );
    Irssi::command_bind( "tweet_as",                   "cmd_tweet_as" );
    Irssi::command_bind( "retweet",                    "cmd_retweet" );
    Irssi::command_bind( "retweet_as",                 "cmd_retweet_as" );
    Irssi::command_bind( "twitter_broadcast",          "cmd_broadcast" );
    Irssi::command_bind( "twitter_info",               "cmd_info" );
    Irssi::command_bind( "twitter_user",               "cmd_user" );
    Irssi::command_bind( "twitter_reply",              "cmd_reply" );
    Irssi::command_bind( "twitter_reply_as",           "cmd_reply_as" );
    Irssi::command_bind( "twitter_login",              "cmd_login" );
    Irssi::command_bind( "twitter_logout",             "cmd_logout" );
    Irssi::command_bind( "twitter_search",             "cmd_search" );
    Irssi::command_bind( "twitter_switch",             "cmd_switch" );
    Irssi::command_bind( "twitter_subscribe",          "cmd_add_search" );
    Irssi::command_bind( "twitter_unsubscribe",        "cmd_del_search" );
    Irssi::command_bind( "twitter_list_subscriptions", "cmd_list_search" );
    Irssi::command_bind( "twirssi_upgrade",            "cmd_upgrade" );
    Irssi::command_bind( "twirssi_oauth",              "cmd_oauth" );
    Irssi::command_bind( "twitter_updates",            "get_updates" );
    Irssi::command_bind( "twitter_add_follow_extra",   "cmd_add_follow" );
    Irssi::command_bind( "twitter_del_follow_extra",   "cmd_del_follow" );
    Irssi::command_bind( "twitter_list_follow_extra",  "cmd_list_follow" );
    Irssi::command_bind( "twirssi_set_channel",        "cmd_set_channel" );
    Irssi::command_bind( "twirssi_list_channels",      "cmd_list_channels" );
    Irssi::command_bind( "twirssi_set_window",         "cmd_set_window" );
    Irssi::command_bind( "twirssi_list_windows",       "cmd_list_windows" );
    Irssi::command_bind( "bitlbee_away",               "update_away" );
    if ( $settings{use_reply_aliases} ) {
        Irssi::command_bind( "reply",    "cmd_reply" );
        Irssi::command_bind( "reply_as", "cmd_reply_as" );
    }
    Irssi::command_bind(
        "twirssi_dump",
        sub {
            print "twits: ", join ", ",
              map { "u: $_\@" . ref($twits{$_}) } keys %twits;
            print "selected: $user\@$defservice";
            print "friends: ", Dumper \%friends;
            print "blocks: ", Dumper \%blocks;
            print "nicks: ",   join ", ", sort keys %nicks;
            print "searches: ", Dumper \%{ $state{__searches} };
            print "windows: ",  Dumper \%{ $state{__windows} };
            print "channels: ",  Dumper \%{ $state{__channels} };
            print "settings: ",  Dumper \%settings;
            print "last poll: $last_poll";
            if ( open DUMP, ">/tmp/twirssi.cache.txt" ) {
                print DUMP Dumper \%tweet_cache;
                close DUMP;
                print "cache written out to /tmp/twirssi.cache.txt";
            }
        }
    );
    Irssi::command_bind(
        "twirssi_version",
        sub {
            &notice(
                ["error"],
                "Twirssi v$VERSION; "
                  . (
                    $Net::Twitter::VERSION
                    ? "Net::Twitter v$Net::Twitter::VERSION. "
                    : ""
                  )
                  . (
                    $Net::Identica::VERSION
                    ? "Net::Identica v$Net::Identica::VERSION. "
                    : ""
                  )
                  . "JSON in use: "
                  . JSON::Any::handler()
                  . ".  See details at http://twirssi.com/"
            );
        }
    );
    Irssi::command_bind(
        "twitter_delete",
        &gen_cmd(
            "/twitter_delete <username:id>",
            "destroy_status",
            sub { &notice( ["tweet"], "Tweet deleted." ); },
            sub {
                my ( $nick, $num ) = split /:/, lc $_[0], 2;
                $num = $state{__last_tweet}{ &normalize_username($nick) }
                  unless ( defined $num );
                return $state{__ids}{$nick}[$num];
            }
        )
    );
    Irssi::command_bind(
        "twitter_follow",
        &gen_cmd(
            "/twitter_follow <username>",
            "create_friend",
            sub {
                &notice( ["tweet"], "Following $_[0]" );
                $nicks{ $_[0] } = time;
            }
        )
    );
    Irssi::command_bind(
        "twitter_unfollow",
        &gen_cmd(
            "/twitter_unfriend <username>",
            "destroy_friend",
            sub {
                &notice( ["tweet"], "Stopped following $_[0]" );
                delete $nicks{ $_[0] };
            }
        )
    );
    Irssi::command_bind(
        "twitter_device_updates",
        &gen_cmd(
            "/twitter_device_updates none|im|sms",
            "update_delivery_device",
            sub { &notice( ["tweet"], "Device updated to $_[0]" ); }
        )
    );
    Irssi::command_bind(
        "twitter_block",
        &gen_cmd(
            "/twitter_block <username>",
            "create_block",
            sub { &notice( ["tweet"], "Blocked $_[0]" ); }
        )
    );
    Irssi::command_bind(
        "twitter_unblock",
        &gen_cmd(
            "/twitter_unblock <username>",
            "destroy_block",
            sub { &notice( ["tweet"], "Unblock $_[0]" ); }
        )
    );
    Irssi::command_bind(
        "twitter_spam",
        &gen_cmd(
            "/twitter_spam <username>",
            "report_spam",
            sub { &notice( ["tweet"], "Reported $_[0] for spam" ); }
        )
    );
    Irssi::signal_add_last( 'complete word' => \&sig_complete );

    &notice(
        "  %Y<%C(%B^%C)%N                   TWIRSSI v%R$VERSION%N",
        "   %C(_(\\%N           http://twirssi.com/ for full docs",
        "    %Y||%C `%N Log in with /twitter_login, send updates with /tweet"
    );

    my $file = $settings{replies_store};
    if ( $file and -r $file ) {
        if ( open( JSON, $file ) ) {
            local $/;
            my $json = <JSON>;
            close JSON;
            eval {
                my $ref = JSON::Any->jsonToObj($json);
                %state = %$ref;
		# fix legacy vulnerable ids
                for (grep !/^__\w+$/, keys %state) { $state{__ids}{$_} = $state{$_}; delete $state{$_}; }
		# remove legacy broken searches (without service name)
                map { /\@/ or delete $state{__searches}{$_} } keys %{$state{__searches}};
		# convert legacy/broken window tags (without @service, or unnormalized)
                for my $type (keys %{$state{__windows}}) {
                    next if $type eq 'search';           # or $type eq 'default';
                    for my $tag (keys %{$state{__windows}{$type}}) {
                        next if $tag eq 'default';
                        my $new_tag = &normalize_username($tag);
                        next if -1 == index($new_tag, '@') or $new_tag eq $tag;
                        $state{__windows}{$type}{$new_tag} = $state{__windows}{$type}{$tag};
                        delete $state{__windows}{$type}{$tag};
                    }
                }
                my $num = keys %{ $state{__indexes} };
                &notice( sprintf "Loaded old replies from %d contact%s.",
                    $num, ( $num == 1 ? "" : "s" ) );
                &cmd_list_search;
                &cmd_list_follow;
            };
        } else {
            &notice( ["error"], "Failed to load old replies from $file: $!" );
        }
    }

    if ( my $provider = $settings{url_provider} ) {
        &notice("Loading WWW::Shorten::$provider...");
        eval "use WWW::Shorten::$provider;";

        if ($@) {
            &notice(
                ["error"],
                "Failed to load WWW::Shorten::$provider - either clear",
                "short_url_provider or install the CPAN module"
            );
        }
    }

    if ( $settings{usernames} ) {
        &cmd_login();
        &get_updates;
    }

} else {
    Irssi::active_win()
      ->print( "Create a window named "
          . $settings{window}
          . " or change the value of twitter_window.  Then, reload twirssi." );
}

# vim: set sts=4 expandtab:
