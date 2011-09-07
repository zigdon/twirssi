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

$VERSION = sprintf '%s', q$Version: v2.5.1beta3$ =~ /^\w+:\s+v(\S+)/;
%IRSSI   = (
    authors     => 'Dan Boger',
    contact     => 'zigdon@gmail.com',
    name        => 'twirssi',
    description => 'Send twitter updates using /tweet.  '
      . 'Can optionally set your bitlbee /away message to same',
    license => 'GNU GPL v2',
    url     => 'http://twirssi.com',
    changed => '$Date: 2011-07-27 22:20:01 +0000$',
);

my $twit;	# $twit is current logged-in Net::Twitter object (usually one of %twits)
my %twits;	# $twits{$username} = logged-in object
my %oauth;
my $user;	# current $account
my $defservice; # current $service
my $poll_event;		# timeout_add event object (regular update)
my %last_poll;		# $last_poll{$username}{tweets|friends|blocks}	= time of last update
			#	    {__interval|__poll}			= time
my %nicks;              # $nicks{$screen_name} = last seen/mentioned time (for sorting completions)
my %friends;		# $friends{$username}{$nick} = $epoch_when_refreshed (rhs value used??)
my %blocks;		# $blocks {$username}{$nick} = $epoch_when_refreshed (rhs value used??)
my %tweet_cache;	# $tweet_cache{$tweet_id} = time of tweet (helps keep last hour of IDs, to avoid dups)
my %state;
		# $state{__ids}			{$lc_nick}[$cache_idx]	= $tweet_id
		# $state{__tweets}		{$lc_nick}[$cache_idx]	= $tweet_text
		# $state{__usernames}		{$lc_nick}[$cache_idx]	= $username_that_polled_tweet
		# $state{__reply_to_ids}	{$lc_nick}[$cache_idx]	= $polled_tweet_replies_to_this_id
		# $state{__reply_to_users}	{$lc_nick}[$cache_idx]	= $polled_tweet_replies_to_this_user
		# $state{__created_ats}		{$lc_nick}[$cache_idx]	= $time_of_tweet
		# $state{__indexes}		{$lc_nick}		= $last_cache_idx_used
		# $state{__last_id}	{$username}{timeline|reply|dm}	= $id_of_last_tweet
		#				   {__sent}		= $id_of_last_tweet_from_act
		#				   {__extras}{$lc_nick}	= $id_of_last_tweet (fix_replies)
		#				   {__search}{$topic}	= $id_of_last_tweet
		# $state{__channels}	{$type}{$tag}{$net_tag}		= [ channel,... ]
		# $state{__windows}	{$type}{$tag}			=  $window_name
my $failstatus = 0;		# last update status:  0=ok, 1=warned, 2=failwhaled
my $first_call = 1;
my $child_pid;
my %fix_replies_index;	# $fix_replies_index($username} = 0..100 idx in sort keys $state{__last_id}{$username}{__extras}
my %search_once;
my $update_is_running = 0;
my %logfile;
my %settings;
my %last_ymd;		# $last_ymd{$chan_or_win} = $last_shown_ymd
my @datetime_parser;
my %completion_types = ();

my $local_tz = DateTime::TimeZone->new( name => 'local' );

my @settings_defn = (
        [ 'broadcast_users',   'twirssi_broadcast_users',   's', undef,			'list{,}' ],
        [ 'charset',           'twirssi_charset',           's', 'utf8', ],
        [ 'default_service',   'twirssi_default_service',   's', 'Twitter', ],
        [ 'ignored_accounts',  'twirssi_ignored_accounts',  's', '',			'list{,},norm_user' ],
        [ 'ignored_twits',     'twirssi_ignored_twits',     's', '',			'lc,list{,}' ],
        [ 'ignored_tags',      'twirssi_ignored_tags',      's', '',			'lc,list{,}' ],
        [ 'location',          'twirssi_location',          's', Irssi::get_irssi_dir . "/scripts/$IRSSI{name}.pl" ],
        [ 'nick_color',        'twirssi_nick_color',        's', '%B', ],
        [ 'ymd_color',         'twirssi_ymd_color',         's', '%r', ],
        [ 'oauth_store',       'twirssi_oauth_store',       's', Irssi::get_irssi_dir . "/scripts/$IRSSI{name}.oauth" ],
        [ 'replies_store',     'twirssi_replies_store',     's', Irssi::get_irssi_dir . "/scripts/$IRSSI{name}.json" ],
        [ 'dump_store',        'twirssi_dump_store',        's', Irssi::get_irssi_dir . "/scripts/$IRSSI{name}.dump" ],
        [ 'retweet_format',    'twirssi_retweet_format',    's', 'RT $n: "$t" ${-- $c$}' ],
        [ 'stripped_tags',     'twirssi_stripped_tags',     's', '',			'list{,}' ],
        [ 'topic_color',       'twirssi_topic_color',       's', '%r', ],
        [ 'timestamp_format',  'twirssi_timestamp_format',  's', '%H:%M:%S', ],
        [ 'window_priority',   'twirssi_window_priority',   's', 'account', ],
        [ 'upgrade_branch',    'twirssi_upgrade_branch',    's', 'master', ],
        [ 'upgrade_dev',       'twirssi_upgrade_dev',       's', 'zigdon', ],
        [ 'bitlbee_server',    'bitlbee_server',            's', 'bitlbee' ],
        [ 'hilight_color',     'twirssi_hilight_color',     's', '%M' ],
        [ 'passwords',         'twitter_passwords',         's', undef,			'list{,}' ],
        [ 'usernames',         'twitter_usernames',         's', undef,			'list{,}' ],
        [ 'update_usernames',  'twitter_update_usernames',  's', undef,			'list{,}' ],
        [ 'url_provider',      'short_url_provider',        's', 'TinyURL' ],
        [ 'url_args',          'short_url_args',            's', undef ],
        [ 'window',            'twitter_window',            's', 'twitter' ],
        [ 'debug_win_name',    'twirssi_debug_win_name',    's', '' ],

        [ 'always_shorten',    'twirssi_always_shorten',    'b', 0 ],
        [ 'avoid_ssl',         'twirssi_avoid_ssl',         'b', 0 ],
        [ 'debug',             'twirssi_debug',             'b', 0 ],
        [ 'notify_timeouts',   'twirssi_notify_timeouts',   'b', 1 ],
        [ 'logging',           'twirssi_logging',           'b', 0 ],
        [ 'mini_whale',        'twirssi_mini_whale',        'b', 0 ],
        [ 'own_tweets',        'show_own_tweets',           'b', 1 ],
        [ 'to_away',           'tweet_to_away',             'b', 0 ],
        [ 'upgrade_beta',      'twirssi_upgrade_beta',      'b', 1 ],
        [ 'use_oauth',         'twirssi_use_oauth',         'b', 1 ],
        [ 'use_reply_aliases', 'twirssi_use_reply_aliases', 'b', 0 ],
        [ 'window_input',      'tweet_window_input',        'b', 0 ],
        [ 'retweet_classic',   'retweet_classic',           'b', 0 ],
        [ 'retweet_show',      'retweet_show',              'b', 0 ],
        [ 'force_first',       'twirssi_force_first',       'b', 0 ],

        [ 'friends_poll',      'twitter_friends_poll',      'i', 600 ],
        [ 'blocks_poll',       'twitter_blocks_poll',       'i', 900 ],
        [ 'poll_interval',     'twitter_poll_interval',     'i', 300 ],
        [ 'poll_schedule',     'twitter_poll_schedule',     's', '',			'list{,}' ],
        [ 'search_results',    'twitter_search_results',    'i', 5 ],
        [ 'autosearch_results','twitter_autosearch_results','i', 0 ],
        [ 'timeout',           'twitter_timeout',           'i', 30 ],
        [ 'track_replies',     'twirssi_track_replies',     'i', 100 ],
);

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

    my ( $target, $text ) = split ' ', $data, 2;
    unless ( $target and $text ) {
        &notice( ["dm"], "Usage: /dm <nick> <message>" );
        return;
    }

    &cmd_direct_as( "$user $data", $server, $win );
}

sub cmd_direct_as {
    my ( $data, $server, $win ) = @_;

    my ( $username, $target, $text ) = split ' ', $data, 3;
    unless ( $username and $target and $text ) {
        &notice( ["dm"], "Usage: /dm_as <username> <nick> <message>" );
        return;
    }

    return unless $username = &valid_username($username);
    return unless &logged_in($twits{$username});

    my $target_norm = &normalize_username($target, 1);

    $text = &shorten($text);

    return if &too_long($text, ['dm', $target_norm]);

    eval {
        if ( $twits{$username}
            ->new_direct_message( { user => $target, text => $text } ) ) {
            &notice( [ "dm", $target_norm ], "DM sent to $target: $text" );
            $nicks{$target} = time;
        } else {
            my $error;
            eval {
                $error = JSON::Any->jsonToObj( $twits{$username}->get_error() );
                $error = $error->{error};
            };
            die "$error\n" if $error;
            &notice( [ "dm", $target_norm ], "DM to $target failed" );
        }
    };

    if ($@) {
        &notice( ["error"], "DM caused an error: $@" );
        return;
    }
}

sub cmd_retweet {
    my ( $data, $server, $win ) = @_;

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

    $data =~ s/^\s+|\s+$//;
    ( my $username, my $id, $data ) = split ' ', $data, 3;

    unless ($username) {
        &notice( ["tweet"],
            "Usage: /retweet_as <username> <nick[:num]> [comment]" );
        return;
    }

    return unless $username = &valid_username($username);

    return unless &logged_in($twits{$username});

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

# Irssi::settings_add_str( $IRSSI{name}, "twirssi_retweet_format", 'RT $n: $t ${-- $c$}' );
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

    return if ($modified or $settings{retweet_classic})
              and &too_long($data, ['tweet', $username]);

    my $success = 1;
    my $extra_info = '';
    eval {
        if ($modified or $settings{retweet_classic}) {
            $success = $twits{$username}->update(
                {
                    status => $data,
                    # in_reply_to_status_id => $state{__ids}{ lc $nick }[$id]
                }
            );
            $extra_info = ' (classic/edited)';
        } else {
            $success =
              $twits{$username}->retweet( { id => $state{__ids}{ lc $nick }[$id] } );
            # $retweeted_id{$username}{ $state{__ids}{ lc $nick }[$id] } = 1;
            $extra_info = ' (native)';
        }
    };
    unless ($success) {
        &notice( [ "tweet", $username ], "Update failed" );
        return;
    }

    if ($@) {
        &notice( [ "error", $username ],
            "Update caused an error: $@.  Aborted" );
        return;
    }

    $extra_info .= ' id=' . $success->{id} if $settings{debug};

    foreach ( $data =~ /@([-\w]+)/g ) {
        $nicks{$_} = time;
    }

    &notice( [ "tweet", $username ], "Retweet of $nick:$id sent" . $extra_info );
}


sub cmd_retweet_to_window {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//;

    ( my $id, $data ) = split ' ', $data, 2;
    $id =~ s/[^\w\d\-:]+//g;
    ( my $nick, $id ) = split ':', $id;
    unless ( exists $state{__ids}{ lc $nick } ) {
        &notice( [ "tweet" ],
            "Can't find a tweet from $nick to retweet!" );
        return;
    }

    $id = $state{__indexes}{lc $nick} unless $id;
    unless ( $state{__ids}{ lc $nick }[$id] ) {
        &notice( [ "tweet" ],
            "Can't find a tweet numbered $id from $nick to retweet!" );
        return;
    }

    unless ( $state{__tweets}{ lc $nick }[$id] ) {
        &notice( [ "tweet" ],
            "The text of this tweet isn't saved, sorry!" );
        return;
    }

    my $target = '';
    my $got_net = 0;
    my $got_target = 0;
    while (not $got_target and $data =~ s/^(\S+)\s*//) {
        my $arg = $1;
        if (not $got_net and lc($arg) ne '-channel' and lc($arg) ne '-nick' and $arg =~ /^-/) {
            $got_net = 1;
        } else {
            if (lc($arg) eq '-channel' or lc($arg) eq '-nick') {
                last if not $data =~ s/^(\S+)\s*//;
                $arg .= " $1";
            }
            $got_target = 1;
        }
        $target .= ($target ne '' ? ' ' : '') . $arg;
    }
    if (not $got_target) {
        &notice( [ "tweet" ], "Missing target." );
        return;
    }

    my $text = $settings{retweet_format};
    $text =~ s/\$n/\@$nick/g;
    if ($data) {
        $text =~ s/\${|\$}//g;
        $text =~ s/\$c/$data/;
    } else {
        $text =~ s/\${.*?\$}//;
    }
    $text =~ s/\$t/$state{__tweets}{ lc $nick }[$id]/;

    $server->command("msg $target $text");

    foreach ( $text =~ /@([-\w]+)/g ) {
        $nicks{$_} = time;
    }

    &debug("Retweet of $nick:$id sent to $target");
}

sub cmd_tweet {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//;
    unless ($data) {
        &notice( ["tweet"], "Usage: /tweet <update>" );
        return;
    }

    &cmd_tweet_as( "$user\@$defservice $data", $server, $win );
}

sub cmd_tweet_as {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//;
    $data =~ s/\s\s+/ /g;
    ( my $username, $data ) = split ' ', $data, 2;

    unless ( $username and $data ) {
        &notice( ["tweet"], "Usage: /tweet_as <username> <update>" );
        return;
    }

    return unless $username = &valid_username($username);

    return unless &logged_in($twits{$username});

    $data = &shorten($data);

    return if &too_long($data, ['tweet', $username]);

    my $success = 1;
    my $res;
    eval {
        unless ( $res = $twits{$username}->update($data) ) {
            &notice( [ "tweet", $username ], "Update failed" );
            $success = 0;
        }
    };
    return unless $success;

    if ($@) {
        &notice( [ "error", $username ],
            "Update caused an error: $@.  Aborted." );
        return;
    }

    foreach ( $data =~ /@([-\w]+)/g ) {
        $nicks{$_} = time;
    }

    # TODO: What's the official definition of a Hashtag? Let's use #[-\w]+ like above for now.
    if ( $settings{autosearch_results} > 0 and $data =~ /#[-\w]+/ ) {
	my @topics;
	while ( $data =~ /(#[-\w]+)/g ) {
	    push @topics, $1;
	    $search_once{$username}->{$1} = $settings{autosearch_results};
	}
	&get_updates([ 0, [
			   [ $username, { up_searches => [ @topics ] } ],
		       ],
		     ]);
    }

    $state{__last_id}{$username}{__sent} = $res->{id};
    my $id_info = ' id=' . $res->{id} if $settings{debug};

    my $away_info = '';
    if ( $username eq "$user\@$defservice"
          and $settings{to_away}
          and &update_away($data) ) {
        $away_info = " (and away msg set)";
    }
    &notice( [ "tweet", $username ], "Update sent" . $away_info . $id_info );
}

sub cmd_broadcast {
    my ( $data, $server, $win ) = @_;

    my @bcast_users = @{ $settings{broadcast_users} };
    @bcast_users = keys %twits if not @bcast_users;

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

    $data =~ s/^\s+|\s+$//;
    ( my $username, my $id, $data ) = split ' ', $data, 3;

    unless ( $username and $data ) {
        &notice( ["reply"],
            "Usage: /reply_as <username> <nick[:num]> <update>" );
        return;
    }

    return unless $username = &valid_username($username);

    return unless &logged_in($twits{$username});

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

    return if &too_long($data, ['reply', $username]);

    my $success = 1;
    eval {
        unless (
            $twits{$username}->update(
                {
                    status                => $data,
                    in_reply_to_status_id => $state{__ids}{ lc $nick }[$id]
                }
            )
          ) {
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

    my $away = $settings{to_away} ? &update_away($data) : 0;

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
            unless ( $twit->$api_name($data) ) {
                &notice("$api_name failed");
                $success = 0;
            }
        };
        return unless $success;

        if ($@) {
            &notice(['error'], "$api_name caused an error.  Aborted: $@");
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
        &get_updates([ 0, [
                                [ $username, { up_searches => [ $data ] } ],
                        ],
        ]);
    } else {
        &notice( ["search"], "Usage: /twitter_search <search term>" );
    }
}


sub cmd_dms_as {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//g;
    ( my $username, $data ) = split ' ', $data, 2;
    unless ( $username ) {
        &notice( ['dm'], 'Usage: /twitter_dms_as <username>' );
        return;
    }
    return unless $username = &valid_username($username);
    return unless &logged_in($twits{$username});

    if ( length $data > 0 ) {
        &notice( ['error'], 'Usage: /' .
                      ($username eq "$user\@$defservice"
                          ? 'twitter_dms' : 'twitter_dms_as <username>') );
        return;
    }
    &notice( [ 'dm' ], 'Fetching direct messages' );
    &get_updates([ 0, [
                          [ $username, { up_dms => 1 } ],
                      ],
    ]);
}


sub cmd_dms {
    my ( $data, $server, $win ) = @_;
    &cmd_dms_as("$user $data", $server, $win);
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
    delete $last_poll{$data};
    undef $twit;
    if ( keys %twits ) {
        &cmd_switch( ( keys %twits )[0], $server, $win );
    } else {
        Irssi::timeout_remove($poll_event) if $poll_event;
        undef $poll_event;
    }
}

sub cmd_login {
    my ( $data, $server, $win ) = @_;
    my $username;
    my $pass;
    &debug("logging in: $data");
    if ($data) {
        ( $username, $pass ) = split ' ', $data, 2;
        unless ( $settings{use_oauth} or $pass ) {
            &notice( ["tweet"],
                "usage: /twitter_login <username>[\@<service>] <password>" );
            return;
        }
        &debug("%G$username%n manual data login");

    } elsif ( $settings{use_oauth} and @{ $settings{usernames} } ) {
        &debug("oauth autouser login @{ $settings{usernames} }" );
        %nicks = ();
        my $some_success = 0;
        foreach my $user ( @{ $settings{usernames} } ) {
            $some_success = &cmd_login($user);
        }
        return $some_success;

    } elsif ( @{ $settings{usernames} } and @{ $settings{passwords} } ) {
        &debug("autouser login");

        # if a password ends with a '\', it was meant to escape the comma, and
        # it should be concatinated with the next one
        for (my $i = 0;  $i+1 < @{ $settings{passwords} };  $i++) {
            while ( $settings{passwords}->[$i] =~ /\\$/ ) {
                $settings{passwords}->[$i] .= "," . delete $settings{passwords}->[$i+1];
            }
        }

        if ( @{ $settings{usernames} } != @{ $settings{passwords} } ) {
            &notice( ["error"],
                    "Number of usernames doesn't match "
                  . "the number of passwords - auto-login failed" );
            return;
        } else {
            %nicks = ();
            my $some_success = 0;
            for (my $i = 0;  $i < @{ $settings{usernames} };  $i++) {
                $some_success ||= &cmd_login("$settings{usernames}->[$i] $settings{passwords}->[$i]");
            }
            return $some_success;
        }

    } else {
        &notice( ["error"],
                "/twitter_login requires either a username/password "
              . "or twitter_usernames and twitter_passwords to be set. "
              . "Note that if twirssi_use_oauth is true, passwords are "
              . "not required" );
        return;
    }

    $username = &normalize_username($username, 1);
    ( $user, $defservice ) = split('@', $username, 2);

    $blocks{$username} = {};
    $friends{$username} = {};

    if ( $defservice eq 'Twitter' and $settings{use_oauth} ) {
        &debug("%G$username%n Attempting OAuth");
        eval {
            if ( $defservice eq 'Identica' ) {
                $twit = Net::Twitter->new(
                    identica => 1,
                    traits   => [ 'API::REST', 'API::Search' ],
                    source   => "twirssi",	# XXX
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
                    source => "twirssi",	# XXX
                    ssl    => !$settings{avoid_ssl},
                );
            }
        };

        if ($@) {
            &notice( ["error"], "Error when creating object:  $@" );
        }

        if ($twit) {
            if ( open( my $oa_fh, '<', $settings{oauth_store} ) ) {
                while (<$oa_fh>) {
                    chomp;
                    next unless /^$username (\S+) (\S+)/i;
                    &debug("%G$username%n Trying cached oauth creds");
                    $twit->access_token($1);
                    $twit->access_token_secret($2);
                    last;
                }
                close $oa_fh;
            }

            unless ( $twit->authorized ) {
                my $url;
                eval { $url = $twit->get_authorization_url; };

                if ($@) {
                    &notice( ["error"],
                        "Failed to get OAuth authorization_url: $@" );
                    return;
                }
                &notice( ["error"],
                    "$user: $IRSSI{name} not authorized to access $defservice.",
                    "Please authorize at the following url, then enter the PIN",
                    "supplied with /twirssi_oauth $username <pin>",
                    $url
                );

                $oauth{pending}{$username} = $twit;
                return;
            }
        }
    } else {
        $twit = Net::Twitter->new(
            $defservice eq 'Identica' ? ( identica => 1 ) : (),
            username => $user,
            password => $pass,
            source   => "twirssi",	# XXX
            ssl      => $settings{avoid_ssl},
        );
    }

    unless ($twit) {
        &notice( ["error"], "Failed to create object!  Aborting." );
        return;
    }

    return &verify_twitter_object( $server, $win, $user, $defservice, $twit );
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
        if ( open( my $oa_fh, '<', $store_file ) ) {
            while (<$oa_fh>) {
                chomp;
                next if /$key/i;
                push @store, $_;
            }
            close $oa_fh;

        }

        push @store, "$key $access_token $access_token_secret";

        if ( open( my $oa_fh, '>', "$store_file.new" ) ) {
            print $oa_fh "$_\n" foreach @store;
            close $oa_fh;
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

sub rate_limited {
    my $obj      = shift;
    my $username = shift;
    my $fh       = shift;

    my $rate_limit;
    eval {
        $rate_limit = $obj->rate_limit_status();
    };
    if ( $rate_limit and $rate_limit->{remaining_hits} < 1 ) {
        &notice( [ 'error', $username, $fh ],
            "Rate limit exceeded, try again after $rate_limit->{reset_time}" );
        return 1;
    }
    return 0;
}

sub verify_twitter_object {
    my ( $server, $win, $user, $service, $twit ) = @_;

    if ( my $timeout = $settings{timeout} and $twit->can('ua') ) {
        $twit->ua->timeout($timeout);
        &notice( ["tweet", "$user\@$service"],
                 "Twitter timeout set to $timeout" );
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

    if (&rate_limited($twit, "$user\@$service")) {
        $twit = undef;
        return;
    }

    &debug("%G$user\@$service%n saving object");
    $twits{"$user\@$service"} = $twit;

    # &get_updates([ 1, [ "$user\@$service", {} ], ]);
    &ensure_updates();

if (0) { # XXX
    &notice( [ "tweet", "$user\@$service" ],
        "Logged in as $user\@$service, loading friends list and blocks..." );
    &get_friends($twit, "$user\@$service", undef, 1);
    &notice( [ "tweet", "$user\@$service" ],
        "loaded friends: " . scalar keys %{ $friends{"$user\@$service"} } );
    &get_blocks($twit, "$user\@$service", undef, 1);
    &notice( [ "tweet", "$user\@$service" ],
        "loaded blocks: " . scalar keys %{ $blocks{"$user\@$service"} } );
}

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

    if ( exists $state{__last_id}{"$user\@$defservice"}{__extras}{$data} ) {
        &notice( ["tweet"], "Already following all replies by \@$data" );
        return;
    }

    $state{__last_id}{"$user\@$defservice"}{__extras}{$data} = 1;
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

    unless ( exists $state{__last_id}{"$user\@$defservice"}{__extras}{$data} ) {
        &notice( ["error"], "Wasn't following all replies by \@$data" );
        return;
    }

    delete $state{__last_id}{"$user\@$defservice"}{__extras}{$data};
    &notice( ["tweet"], "Will no longer follow all replies by \@$data" );
}

sub cmd_list_follow {
    my ( $data, $server, $win ) = @_;

    my $found = 0;
    foreach my $suser ( sort keys %{ $state{__last_id} } ) {
        next unless exists $state{__last_id}{$suser}{__extras};
        my $frusers = join ', ', sort keys %{ $state{__last_id}{$suser}{__extras} };
        if ($frusers) {
            $found = 1;
            &notice( ["tweet"], "Following all replies as $suser: $frusers" );
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

    my $want_win = 1 if $data =~ s/^\s*-w\s+//;

    $data =~ s/^\s+|\s+$//g;
    $data = lc $data;

    unless ($data) {
        &notice( ["search"], "Usage: /twitter_subscribe [-w] <topic>" );
        return;
    }

    if ( exists $state{__last_id}{"$user\@$defservice"}{__search}{$data} ) {
        &notice( [ "search", $data ],
            "Already had a subscription for '$data'" );
        return;
    }

    $state{__last_id}{"$user\@$defservice"}{__search}{$data} = 1;
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

    unless ( exists $state{__last_id}{"$user\@$defservice"}{__search}{$data} ) {
        &notice( [ "search", $data ], "No subscription found for '$data'" );
        return;
    }

    delete $state{__last_id}{"$user\@$defservice"}{__search}{$data};
    &notice( [ "search", $data ], "Removed subscription for '$data'" );
}

sub cmd_list_search {
    my ( $data, $server, $win ) = @_;

    my $found = 0;
    foreach my $suser ( sort keys %{ $state{__last_id} } ) {
        my $topics;
        foreach my $topic ( sort keys %{ $state{__last_id}{$suser}{__search} } ) {
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
        eval " use Digest::MD5; ";

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

        my $fh;
        unless ( open( $fh, '<', $loc ) ) {
            &notice( ["error"],
                    "Failed to read $loc."
                  . "  Check that /set twirssi_location is set to the correct location."
            );
            return;
        }

        my $cur_md5 = Digest::MD5::md5_hex(<$fh>);
        close $fh;

        if ( $cur_md5 eq $md5 ) {
            &notice( ["error"], "Current twirssi seems to be up to date." );
            return;
        }
    }

    my $URL =
      $settings{upgrade_beta}
      ? "http://github.com/$settings{upgrade_dev}/twirssi/raw/$settings{upgrade_branch}/twirssi.pl"
      : "http://twirssi.com/twirssi.pl";
    &notice( ["notice"], "Downloading twirssi from $URL" );
    LWP::Simple::getstore( $URL, "$loc.upgrade" );

    unless ( -s "$loc.upgrade" ) {
        &notice( ["error"],
                "Failed to save $loc.upgrade."
              . "  Check that /set twirssi_location is set to the correct location."
        );
        return;
    }

    unless ( $data or $settings{upgrade_beta} ) {
        my $fh;
        unless ( open( $fh, '<', "$loc.upgrade" ) ) {
            &notice( ["error"],
                    "Failed to read $loc.upgrade."
                  . "  Check that /set twirssi_location is set to the correct location."
            );
            return;
        }

        my $new_md5 = Digest::MD5::md5_hex(<$fh>);
        close $fh;

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
        &notice( ["notice"], "Updating $dir/autorun/$file" );
        unlink "$dir/autorun/$file"
          or
          &notice( ["error"], "Failed to remove old $file from autorun: $!" );
        symlink "../$file", "$dir/autorun/$file"
          or &notice( ["error"],
            "Failed to create symlink in autorun directory: $!" );
    }

    &notice( ["notice"],
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
    &notice("Type can be one of: tweet, reply, dm, search, sender, error.",
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

    my @valid_types = qw/ tweet search dm reply sender error * /;

    unless ( grep { $type eq $_ } @valid_types ) {
        &notice(['error'], "Invalid message type '$type'.");
        &notice(['error'], 'Valid types: ' . join(', ', @valid_types));
        return;
    }

    $tag = &normalize_username($tag) unless grep { $type eq $_ } qw/ search sender * /
                or $tag eq '*';

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

    my @valid_types = qw/ tweet search dm reply sender error default /;

    if ( @words == 0 ) {            # just a window name
        $winname = 'twitter' if $delete;
        &notice("Changing the default twirssi window to $winname");
        Irssi::settings_set_str( "twitter_window", $winname );
        &ensure_logfile($settings{window} = $winname);
     } elsif ( @words > 2 ) {
        &notice(
                "Too many arguments to /twirssi_set_window. '@words'",
                "Usage: /twirssi_set_window [type] [account|search_term] [window].",
                'Valid types: ' . join(', ', @valid_types)
        );
        return;
    } elsif ( @words >= 1 ) {
        my $type = lc $words[0];
        unless ( grep { $_ eq $type } @valid_types ) {
            &notice(['error'],
                "Invalid message type '$type'.",
                'Valid types: ' . join(', ', @valid_types)
            );
            return;
        }

        my $tag = "default";
        if ( @words == 2 ) {
           $tag = lc $words[1];
           if ($type eq 'sender') {
              $tag =~ s/^\@//;
              $tag =~ s/\@.+//;
           } elsif ($type ne 'search'
                   and ($type ne 'default' or index($tag, '@') >= 0)
                   and $tag ne 'default') {
              $tag = &normalize_username($tag);
           }
           if (substr($tag, -1, 1) eq '@') {
              &notice(['error'], "Invalid tag '$tag'.");
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

sub get_friends {
    my $u_twit    = shift;
    my $username  = shift;
    my $fh        = shift;
    my $is_update = shift;

    my $cursor      = -1;
    my %new_friends = ();
    eval {
        for my $page (1..10) {
            &debug($fh, "%G$username%n Loading friends page $page...");
            my $friends;
            if ( $username =~ /\@Twitter/ ) {
                $friends = $u_twit->friends( { cursor => $cursor } );
                last unless $friends;
                $cursor  = $friends->{next_cursor};
                $friends = $friends->{users};
            } else {
                $friends = $u_twit->friends( { page => $page } );
                last unless $friends;
            }
            $new_friends{ $_->{screen_name} } = time foreach @$friends;
            last if $cursor eq '0';
        }
    };

    if ($@) {
        &notice(['error', $username, $fh], "$username: Error updating friends list.  Aborted.");
        &debug($fh, "%G$username%n Error updating friends list: $@");
        return;
    }

    return \%new_friends if not $is_update;

    my ( $added, $removed ) = ( 0, 0 );
    # &debug($fh, "%G$username%n Scanning for new friends...");
    foreach ( keys %new_friends ) {
        next if exists $friends{$username}{$_};
        $friends{$username}{$_} = $new_friends{$_};
        $added++;
    }

    # &debug($fh, "%G$username%n Scanning for removed friends...");
    foreach ( keys %{ $friends{$username} } ) {
        next if exists $new_friends{$_};
        delete $friends{$username}{$_};
        &debug($fh, "%G$username%n removing friend: $_");
        $removed++;
    }

    return ( $added, $removed );
}

sub get_blocks {
    my $u_twit    = shift;
    my $username  = shift;
    my $fh        = shift;
    my $is_update = shift;

    my %new_blocks = ();
    eval {
        for my $page (1..10) {
            &debug($fh, "%G$username%n Loading blocks page $page...");
            my $blocks = $u_twit->blocking( { page => $page } );
            last if not defined $blocks or @$blocks == 0
                    or defined $new_blocks{ $blocks->[0]->{screen_name} };
            &debug($fh, "%G$username%n Blocks page $page... " . scalar(@$blocks)
                        . " first block: " . $blocks->[0]->{screen_name});
            $new_blocks{ $_->{screen_name} } = time foreach @$blocks;
        }
    };

    if ($@) {
        &notice(['error', $username, $fh], "$username: Error updating blocks list.  Aborted.");
        &debug($fh, "%G$username%n Error updating blocks list: $@");
        return;
    }

    return \%new_blocks if not $is_update;

    my ( $added, $removed ) = ( 0, 0 );
    # &debug($fh, "%G$username%n Scanning for new blocks...");
    foreach ( keys %new_blocks ) {
        next if exists $blocks{$username}{$_};
        $blocks{$username}{$_} = time;
        $added++;
    }

    # &debug($fh, "%G$username%n Scanning for removed blocks...");
    foreach ( keys %{ $blocks{$username} } ) {
        next if exists $new_blocks{$_};
        delete $blocks{$username}{$_};
        &debug($fh, "%G$username%n removing block: $_");
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

sub cmd_wipe {
    my ( $data, $server, $win ) = @_;
    my @cache_keys = qw/ __tweets __indexes __ids
			__usernames __reply_to_ids __reply_to_users __created_ats /;
    my @surplus_nicks = ();
    if ($data eq '') {
        for my $nick (keys %{ $state{__tweets} }) {
            my $followed = 0;
            for my $acct (keys %twits) {
                if (grep { lc($_) eq $nick } keys %{ $friends{$acct} }) {
                    $followed = 1;
                    last;
                }
            }
            push @surplus_nicks, $nick if not $followed;
        }
    } else {
        for my $to_wipe (split(/\s+/, $data)) {
            if (exists $state{$to_wipe}) {
                &notice("Wiping '$to_wipe' state.");
                $state{$to_wipe} = {};
            } elsif ($to_wipe eq '-f') {
                push @surplus_nicks, keys %{ $state{__tweets} };
            } elsif ($to_wipe eq '-A') {
                &notice('Wiping all info/settings.');
                %state = ();
            } else {
                &notice([ 'error' ], "Error: no such twirssi_wipe argument '$to_wipe'.");
            }
        }
    }
    if (@surplus_nicks) {
        for my $surplus_nick (@surplus_nicks) {
            for my $cache_key (@cache_keys) {
                delete $state{$cache_key}{$surplus_nick};
            }
        }
        &debug('Wiped data for ' . join(',', @surplus_nicks));
        &notice('Wiped data for ' . (0+@surplus_nicks) . ' nicks.');
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
        &notice([ 'error' ], "Error during user_timeline $target call: Aborted.");
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
        and not exists $friends{$username}{ $t->{in_reply_to_screen_name} } ) {
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
                printf $fh "t:tweet id:%s ac:%s %snick:%s created_at:%s %s\n",
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

sub background_setup {
    my $pause_monitor = shift || 5000;
    my $max_pauses    = shift || 24;
    my $is_update     = shift;
    my $fn_to_call    = shift;
    my $fn_args_ref   = shift;

    &debug("bg_setup starting upd=$is_update");

    return unless &logged_in($twit);

    my ( $fh, $filename ) = File::Temp::tempfile();
    binmode( $fh, ":" . &get_charset() );
    $child_pid = fork();

    if ($child_pid) {                   # parent
        Irssi::timeout_add_once( $pause_monitor, 'monitor_child',
            [ "$filename.done", $max_pauses, $pause_monitor, 1 ] );
        Irssi::pidwait_add($child_pid);
    } elsif ( defined $child_pid ) {    # child
        close STDIN;
        close STDOUT;
        close STDERR;

        {
            no strict 'refs';
            &$fn_to_call($fh, @$fn_args_ref);
        }

        close $fh;
        rename $filename, "$filename.done";
        exit;
    } else {
        &notice([ 'error' ], "Failed to fork for background call: $!");
    }
}

sub ensure_updates {
    my $adhoc_interval = shift;
    my $poll_interval = (defined $adhoc_interval ? $adhoc_interval : &get_poll_time) * 1000;
    if ($poll_interval != $last_poll{__interval} or not $poll_event) {
        &debug("get_updates every " . int($poll_interval/1000));
        Irssi::timeout_remove($poll_event) if $poll_event;
        $poll_event = Irssi::timeout_add( $poll_interval, \&get_updates, [ 1 ] );
        $last_poll{__interval} = $poll_interval;
    }
}

sub get_updates {
    my $args = shift;

    my $is_regular = 0;
    my $to_be_updated;
    if (not ref $args) {	# command-line request, so do regular
        $is_regular = 1;
    } else {
        $is_regular    = $args->[0];
        $to_be_updated = $args->[1];
    }

    &debug("get_updates starting upd=$is_regular");

    return unless &logged_in($twit);

    if ($is_regular) {
        if ($update_is_running) {
            &debug("get_updates aborted: already running");
            return;
        }
        $update_is_running = 1;
    }

    if (not defined $to_be_updated) {
        $to_be_updated = [];
        foreach my $pref_user (@{ $settings{update_usernames} }) {
            next unless $pref_user = &valid_username($pref_user);
            next if grep { $_ eq $pref_user } @{ $settings{ignored_accounts} };
            push @$to_be_updated, [ $pref_user, {} ];
        }
        foreach my $other_user (keys %twits) {
            next if grep { $_ eq $other_user } @{ $settings{ignored_accounts} };
            push @$to_be_updated, [ $other_user, {} ]
                 if not grep { $other_user eq $_->[0] } @$to_be_updated;
        }
    }
    &background_setup(5000, (24*@$to_be_updated), $is_regular, 'get_updates_child', [ $is_regular, $to_be_updated ]);

    if ($is_regular) {
        &ensure_updates();
    }
}

sub get_updates_child {
    my $fh            = shift;
    my $is_regular    = shift;
    my $to_be_updated = shift;

    my $time_before_update = time;

    my $error = 0;
    my %context_cache;

    foreach my $update_tuple ( @$to_be_updated ) {
        my $username       = shift @$update_tuple;
        my $what_to_update = shift @$update_tuple;
        my $errors_beforehand = $error;

        if (0 == keys(%$what_to_update)
                or defined $what_to_update->{up_tweets}) {
            $error++ unless &get_tweets( $fh, $username, $twits{$username}, \%context_cache );

            if ( exists $state{__last_id}{$username}{__extras}
                    and keys %{ $state{__last_id}{$username}{__extras} } ) {
                my @frusers = sort keys %{ $state{__last_id}{$username}{__extras} };

                $error++ unless &get_timeline( $fh, $frusers[ $fix_replies_index{$username} ],
                                               $username, $twits{$username}, \%context_cache );

                $fix_replies_index{$username}++;
                $fix_replies_index{$username} = 0
                      if $fix_replies_index{$username} >= @frusers;
                print $fh "t:fix_replies_index idx:$fix_replies_index{$username} ",
                      "ac:$username\n";
            }
        }
        next if $error > $errors_beforehand;

        if (0 == keys(%$what_to_update)
                    or defined $what_to_update->{up_dms}) {
            $error++ unless &do_dms( $fh, $username, $twits{$username}, $is_regular );
        }
        next if $error > $errors_beforehand;

        if (0 == keys(%$what_to_update)
                    or defined $what_to_update->{up_subs}) {
            $error++ unless &do_subscriptions( $fh, $username, $twits{$username}, $what_to_update->{up_subs} );
        }
        next if $error > $errors_beforehand;

        if (0 == keys(%$what_to_update)
                    or defined $what_to_update->{up_searches}) {
            $error++ unless &do_searches( $fh, $username, $twits{$username}, $what_to_update->{up_searches} );
        }
        next if $error > $errors_beforehand;

        if ( (0 == keys(%$what_to_update)
                  and time - $last_poll{$username}{friends} > $settings{friends_poll})
                or defined $what_to_update->{up_friends} ) {
            my $show_friends;
            if ($is_regular) {
                my $time_before = time;
                my ( $added, $removed ) = &get_friends($twits{$username}, $username, $fh, 1);
                print $fh "t:debug %G$username%n Friends list updated: ",
                        "$added added, $removed removed\n" if $added + $removed;
                print $fh "t:last_poll ac:$username poll_type:friends epoch:$time_before\n";
                $show_friends = $friends{$username};
            } else {
                $show_friends = &get_friends($twits{$username}, $username, $fh, 0);
            }
            foreach ( sort keys %$show_friends ) {
                print $fh "t:friend ac:$username nick:$_ epoch:$show_friends->{$_}\n";
            }
        }
        next if $error > $errors_beforehand;

        if ( (0 == keys(%$what_to_update)
                  and time - $last_poll{$username}{blocks} > $settings{blocks_poll} )
                or defined $what_to_update->{up_blocks}) {
            my $show_blocks;
            if ($is_regular) {
                my $time_before = time;
                my ( $added, $removed ) = &get_blocks($twits{$username}, $username, $fh, 1);
                print $fh "t:debug %G$username%n Blocks list updated: ",
                        "$added added, $removed removed\n" if $added + $removed;
                print $fh "t:last_poll ac:$username poll_type:blocks epoch:$time_before\n";
                $show_blocks = $blocks{$username};
            } else {
                $show_blocks = &get_blocks($twits{$username}, $username, $fh, 0);
            }
            foreach ( sort keys %$show_blocks ) {
                print $fh "t:block ac:$username nick:$_ epoch:$show_blocks->{$_}\n";
            }
        }
        next if $error > $errors_beforehand;

    }

    if ($error) {
        &notice( [ 'error', undef, $fh ], "Update encountered errors.  Aborted");
    } else {
        print $fh "t:last_poll poll_type:__poll epoch:$time_before_update\n";
    }
}

sub is_ignored {
    my $text = shift;
    my $twit = shift;

    my $text_no_colors = &remove_colors($text);
    foreach my $tag (@{ $settings{ignored_tags} }) {
        return $tag if $text_no_colors =~ /(?:^|\b|\s)\Q$tag\E(?:\b|\s|$)/i;
    }
    if (defined $twit and grep { $_ eq lc $twit } @{ $settings{ignored_twits} }) {
        return $twit;
    }
    return undef;
}

sub remove_tags {
    my $text = shift;

    foreach my $tag (@{ $settings{stripped_tags} }) {
        $text =~ s/\cC\d{2}\Q$tag\E\cO//gi;   # with then without colors
        $text =~ s/(^|\b|\s)\Q$tag\E(\b|\s|$)/$1$2/gi;
    }
    return $text;
}

sub get_tweets {
    my ( $fh, $username, $obj, $cache ) = @_;

    return if &rate_limited($obj, $username, $fh);

    &debug($fh, "%G$username%n Polling for tweets");
    my $tweets;
    my $new_poll_id = 0;
    eval {
        my %call_attribs = ( page => 1 );
        $call_attribs{count} = $settings{track_replies} if $settings{track_replies};
        # $call_attribs{since_id} = $state{__last_id}{$username}{timeline}
                           # if defined $state{__last_id}{$username}{timeline};
        for ( ; $call_attribs{page} < 2 ; $call_attribs{page}++) {
            &debug($fh, "%G$username%n timeline pg=" . $call_attribs{page});
            my $page_tweets = $obj->home_timeline( \%call_attribs );
            last if not defined $page_tweets or @$page_tweets == 0;
            unshift @$tweets, @$page_tweets;
        }
    };

    if ($@) {
        print $fh "t:error $username Error during home_timeline call: Aborted.\n";
        print $fh "t:debug : $_\n" foreach split /\n/, Dumper($@);
        return;
    }

    unless ( ref $tweets ) {
        if ( $obj->can("get_error") ) {
            my $error = "Unknown error";
            eval { $error = JSON::Any->jsonToObj( $obj->get_error() ) };
            unless ($@) { $error = $obj->get_error() }
            &notice([ 'error', $username, $fh],
                "$username: API Error during home_timeline call: Aborted");
            print $fh "t:debug : $_\n" foreach split /\n/, Dumper($error);

        } else {
            &notice([ 'error', $username, $fh],
                "$username: API Error during home_timeline call. Aborted.");
        }
        return;
    }

    if (0000000 and $settings{debug} and open my $fh_tl, '>', "/tmp/tl-$username.txt" ) {
        print $fh_tl Dumper $tweets;
        close $fh_tl;
    }

    print $fh "t:debug %G$username%n got ", scalar(@$tweets), " tweets, first/last: ",
                        (sort {$a->{id} <=> $b->{id}} @$tweets)[0]->{id}, "/",
                        (sort {$a->{id} <=> $b->{id}} @$tweets)[$#{$tweets}]->{id}, "\n";

    my @own_ids = ();
    foreach my $t ( reverse @$tweets ) {
        my $text = &get_text( $t, $obj );
        $text = &remove_tags($text);
        my $ign = &is_ignored($text, $t->{user}{screen_name});
        $ign = (defined $ign ? 'ign:' . &encode_for_file($ign) . ' ' : '');
        my $reply = &tweet_or_reply($obj, $t, $username, $cache, $fh);
        if ($t->{user}{screen_name} eq $username and not $settings{own_tweets}) {
            push @own_ids, $t->{id};
            next;
        }
        printf $fh "t:%s id:%s ac:%s %s%snick:%s created_at:%s %s\n",
            $reply, $t->{id}, $username, $ign, &get_reply_to($t), $t->{user}{screen_name},
            &encode_for_file($t->{created_at}), $text;

        $new_poll_id = $t->{id} if $new_poll_id < $t->{id};
    }
    &debug($fh, "%G$username%n skip own " . join(', ', @own_ids) . "\n") if @own_ids;
    printf $fh "t:last_id id:%s ac:%s id_type:timeline\n", $new_poll_id, $username;

    &debug($fh, "%G$username%n Polling for replies since " . $state{__last_id}{$username}{reply});
    $new_poll_id = 0;
    eval {
        if ( $state{__last_id}{$username}{reply} ) {
            $tweets = $obj->replies( { since_id => $state{__last_id}{$username}{reply} } )
                      || [];
        } else {
            $tweets = $obj->replies() || [];
        }
    };

    if ($@) {
        print $fh "t:debug %G$username%n Error during replies call.  Aborted.\n";
        return;
    }

    foreach my $t ( reverse @$tweets ) {
        next if exists $friends{$username}{ $t->{user}{screen_name} };

        my $text = &get_text( $t, $obj );
        $new_poll_id = $t->{id} if $new_poll_id < $t->{id};
        $text = &remove_tags($text);
        my $ign = &is_ignored($text);
        $ign = (defined $ign ? 'ign:' . &encode_for_file($ign) . ' ' : '');
        printf $fh "t:tweet id:%s ac:%s %s%snick:%s created_at:%s %s\n",
          $t->{id}, $username, $ign, &get_reply_to($t), $t->{user}{screen_name},
          &encode_for_file($t->{created_at}), $text;
    }
    printf $fh "t:last_id id:%s ac:%s id_type:reply\n", $new_poll_id, $username;
    return 1;
}


sub do_dms {
    my ( $fh, $username, $obj, $is_regular ) = @_;

    my $new_poll_id = 0;

    my $since_args = {};
    if ( $is_regular and $state{__last_id}{$username}{dm} ) {
        $since_args->{since_id} = $state{__last_id}{$username}{dm};
        &debug($fh, "%G$username%n Polling for DMs since_id " .
                         $state{__last_id}{$username}{dm});
    } else {
        &debug($fh, "%G$username%n Polling for DMs");
    }

    my $tweets;
    eval {
        $tweets = $obj->direct_messages($since_args) || [];
    };
    if ($@) {
        &debug($fh, "%G$username%n Error during direct_messages call.  Aborted.");
        return;
    }
    &debug($fh, "%G$username%n got DMs: " . (0+@$tweets));

    foreach my $t ( reverse @$tweets ) {
        my $text = decode_entities( $t->{text} );
        $text =~ s/[\n\r]/ /g;
        printf $fh "t:dm id:%s ac:%s %snick:%s created_at:%s %s\n",
          $t->{id}, $username, &get_reply_to($t), $t->{sender_screen_name},
          &encode_for_file($t->{created_at}), $text;
        $new_poll_id = $t->{id} if $new_poll_id < $t->{id};
    }
    printf $fh "t:last_id id:%s ac:%s id_type:dm\n", $new_poll_id, $username;
    return 1;
}

sub do_subscriptions {
    my ( $fh, $username, $obj, $search_limit ) = @_;

    &debug($fh, "%G$username%n Polling for subscriptions");
    if ( $obj->can('search') and $state{__last_id}{$username}{__search} ) {
        my $search;
        foreach my $topic ( sort keys %{ $state{__last_id}{$username}{__search} } ) {
            next if defined $search_limit and @$search_limit and not grep { $topic eq $_ } @$search_limit;
            print $fh "t:debug %G$username%n Search '$topic' id was ",
              "$state{__last_id}{$username}{__search}{$topic}\n";
            eval {
                $search = $obj->search(
                    {
                        q        => $topic,
                        since_id => $state{__last_id}{$username}{__search}{$topic}
                    }
                );
            };

            if ($@) {
                print $fh
                  "t:debug %G$username%n Error during search($topic) call.  Aborted.\n";
                return;
            }

            unless ( $search->{max_id} ) {
                print $fh "t:debug %G$username%n Invalid search results when searching",
                  " for $topic. Aborted.\n";
                return;
            }

            $state{__last_id}{$username}{__search}{$topic} = $search->{max_id};
            printf $fh "t:searchid id:%s ac:%s topic:%s\n",
              $search->{max_id}, $username, &encode_for_file($topic);

            foreach my $t ( reverse @{ $search->{results} } ) {
                next if exists $blocks{$username}{ $t->{from_user} };
                my $text = &get_text( $t, $obj );
                $text = &remove_tags($text);
                my $ign = &is_ignored($text, $t->{from_user});
                $ign = (defined $ign ? 'ign:' . &encode_for_file($ign) . ' ' : '');
                printf $fh "t:search id:%s ac:%s %snick:%s topic:%s created_at:%s %s\n",
                  $t->{id}, $username, $ign, $t->{from_user}, $topic,
                  &encode_for_file($t->{created_at}), $text;
            }
        }
    }
    return 1;
}

sub do_searches {
    my ( $fh, $username, $obj, $search_limit ) = @_;

    &debug($fh, "%G$username%n Polling for one-time searches");
    if ( $obj->can('search') and exists $search_once{$username} ) {
        my $search;
        foreach my $topic ( sort keys %{ $search_once{$username} } ) {
            next if defined $search_limit and @$search_limit and not grep { $topic eq $_ } @$search_limit;
            my $max_results = $search_once{$username}->{$topic};

            print $fh
              "t:debug %G$username%n search $topic once (max $max_results)\n";
            eval { $search = $obj->search( { 'q' => $topic } ); };

            if ($@) {
                print $fh "t:debug %G$username%n Error during search_once($topic) call.  Aborted.\n";
                return;
            }

            unless ( $search->{max_id} ) {
                print $fh "t:debug %G$username%n Invalid search results when searching once",
                  " for $topic. Aborted.\n";
                return;
            }

            # TODO: consider applying ignore-settings to search results
            my @results = ();
            foreach my $res (@{ $search->{results} }) {
                if (exists $blocks{$username}{ $res->{from_user} }) {
                    print $fh "t:debug %G$username%n blocked $topic: $res->{from_user}\n";
                    next;
                }
                push @results, $res;
            }
            if ( $max_results > 0 ) {
                splice @results, $max_results;
            }
            foreach my $t ( reverse @results ) {
                my $text = &get_text( $t, $obj );
                $text = &remove_tags($text);
                my $ign = &is_ignored($text, $t->{from_user});
                $ign = (defined $ign ? 'ign:' . &encode_for_file($ign) . ' ' : '');
                printf $fh "t:search_once id:%s ac:%s %s%snick:%s topic:%s created_at:%s %s\n",
                  $t->{id}, $username, $ign, &get_reply_to($t), $t->{from_user}, &encode_for_file($topic),
                  &encode_for_file($t->{created_at}), $text;
            }
        }
    }

    return 1;
}

sub get_timeline {
    my ( $fh, $target, $username, $obj, $cache ) = @_;
    my $tweets;
    my $last_id = $state{__last_id}{$username}{__extras}{$target};

    print $fh "t:debug %G$username%n get_timeline("
      . "$fix_replies_index{$username}=$target > $last_id)\n";
    my $arg_ref = { id => $target, };
    $arg_ref->{since_id} = $last_id if $last_id;
    $arg_ref->{include_rts} = 1 if $settings{retweet_show};
    eval {
        $tweets = $obj->user_timeline($arg_ref);
    };

    if ($@) {
        print $fh "t:error $username user_timeline($target) call: Aborted.\n";
        print $fh "t:debug : $_\n" foreach split /\n/, Dumper($@);
        return;
    }

    unless ($tweets) {
        print $fh "t:error $username user_timeline($target) call returned undef!  Aborted\n";
        return 1;
    }

    foreach my $t ( reverse @$tweets ) {
        my $text = &get_text( $t, $obj );
        my $reply = &tweet_or_reply($obj, $t, $username, $cache, $fh);
        printf $fh "t:%s id:%s ac:%s %snick:%s created_at:%s %s\n",
          $reply, $t->{id}, $username, &get_reply_to($t), $t->{user}{screen_name},
          &encode_for_file($t->{created_at}), $text;
        $last_id = $t->{id} if $last_id < $t->{id};
    }
    printf $fh "t:last_id_fixreplies id:%s ac:%s id_type:%s\n",
      $last_id, $username, $target;

    return 1;
}

sub encode_for_file {
    my $datum = shift;
    $datum =~ s/\t/%09/g;
    $datum =~ s/ /%20/g;
    return $datum;
}

sub decode_from_file {
    my $datum = shift;
    $datum =~ s/%20/ /g;
    $datum =~ s/%09/\t/g;
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

    if (defined $meta->{ign}) {
        $line_attribs{ignoring} = 1;
        $line_attribs{marker} = '-' . $meta->{ign};  # must have a marker for tweet theme

    } elsif ( $meta->{type} ne 'dm' and $meta->{nick} and $meta->{id} and not $meta->{ign} ) {
        ### not ignored, so we probably want it cached and create a :marker...
        my $marker;
        my $lc_nick = lc $meta->{nick};
        for (my $mark_idx = 0;
                defined $state{__ids}{ $lc_nick } and $mark_idx < @{ $state{__ids}{ $lc_nick } };
                $mark_idx++) {
            if ($state{__ids}{ $lc_nick }[$mark_idx] eq $meta->{id}) {
                $marker = $mark_idx;
                last;
            }
        }
        if (not defined $marker) {
            $marker = ( $state{__indexes}{ $lc_nick } + 1 ) % $settings{track_replies};
            $state{__ids}    { $lc_nick }[$marker] = $meta->{id};
            $state{__indexes}{ $lc_nick }          = $marker;
            $state{__tweets} { $lc_nick }[$marker] = $meta->{text};
            foreach my $key (qw/username reply_to_id reply_to_user created_at/) {
                # __usernames __reply_to_ids __reply_to_users __created_ats
                $state{"__${key}s"}{ $lc_nick }[$marker] = $meta->{$key} if defined $meta->{$key};
            }
        }
        $line_attribs{marker} = ":$marker";
    }
    return %line_attribs;
}

sub cache_to_meta {
    my $line = shift;
    my $type = shift;
    my %meta = ( type => $type );
    foreach my $key (@{ $_[0] }) {
        if ($line =~ s/^$key:(\S+)\s*//) {
            $key = 'account' if $key eq 'ac';
            $meta{$key} = $1;
            $meta{$key} = &decode_from_file($meta{$key});
            if ($key eq 'account') {
                $meta{username} = &normalize_username($meta{account});	# username is account@Service
                $meta{account} =~ s/\@(\w+)$//;
                $meta{service} = $1;
            } elsif ($key eq 'created_at') {
                $meta{created_at} = &date_to_epoch($meta{created_at});
            }
        }
    }
    $meta{text} = $line;
    return %meta;
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
    # print "date '$orig_date': " . ref($date) if &debug;
    return if not defined $date;
    return $date->epoch();
}

sub monitor_child {
    my $args = shift;

    my $filename       = $args->[0];
    my $attempts_to_go = $args->[1];
    my $wait_time      = $args->[2];
    my $is_update      = $args->[3];

    &debug("checking child log at $filename ($attempts_to_go)");

    # reap any random leftover processes - work around a bug in irssi on gentoo
    waitpid( -1, WNOHANG );

    # first time we run we don't want to print out *everything*, so we just
    # pretend

    my @lines = ();
    my %new_cache = ();
    my %types_per_user = ();
    my $got_errors = 0;

    my $fh;
    if ( -e $filename and open $fh, '<', $filename ) {
        binmode $fh, ":" . &get_charset();
    } else {
        undef $fh;
    }
    while (defined $fh and defined ($_ = <$fh>)) {
        unless (/\n$/) {    # skip partial lines
            &debug($fh, "Skipping partial line: $_");
            next;
        }
        chomp;

        if (s/^t:debug\s+//) {
            &debug($_);

        } elsif (s/^t:error\s+//) {
            $got_errors++;
            &notice(['error'], $_);

        } elsif (s/^t:(last_poll)\s+//) {
            my %meta = &cache_to_meta($_, $1, [ qw/ac poll_type epoch/ ]);

            if ( not defined $meta{ac} and $meta{poll_type} eq '__poll' ) {
                $last_poll{$meta{poll_type}} = $meta{epoch};
            } elsif ( $meta{epoch} >= $last_poll{$meta{username}}{$meta{poll_type}} ) {
                $last_poll{$meta{username}}{$meta{poll_type}} = $meta{epoch};
                &debug("%G$meta{username}%n $meta{poll_type} updated to $meta{epoch}");
            } else {
               &debug("%G$meta{username}%n Impossible! $meta{poll_type}: "
                  . "new poll=$meta{epoch} < prev=$last_poll{$meta{username}}{$meta{poll_type}}!");
               $got_errors++;
            }

        } elsif (s/^t:(fix_replies_index)\s+//) {
            my %meta = &cache_to_meta($_, $1, [ qw/idx ac topic id_type/ ]);
            $fix_replies_index{ $meta{username} } = $meta{idx};
            &debug("%G$meta{username}%n fix_replies_index set to $meta{idx}");

        } elsif (s/^t:(searchid|last_id|last_id_fixreplies)\s+//) {
            my %meta = &cache_to_meta($_, $1, [ qw/id ac topic id_type/ ]);
            if ( $meta{type} eq 'searchid' ) {
                &debug("%G$meta{username}%n Search '$meta{topic}' got id $meta{id}");
                if (not exists $state{__last_id}{ $meta{username} }{__search}{ $meta{topic} }
                        or $meta{id} >= $state{__last_id}{ $meta{username} }{__search}{ $meta{topic} } ) {
                    $state{__last_id}{ $meta{username} }{__search}{ $meta{topic} } = $meta{id};
                } else {
                    &debug("%G$meta{username}%n Search '$meta{topic}' bad id $meta{id}");
                    $got_errors++;
                }
            } elsif ( $meta{type} eq 'last_id') {
                $state{__last_id}{ $meta{username} }{ $meta{id_type} } = $meta{id}
                  if $state{__last_id}{ $meta{username} }{ $meta{id_type} } < $meta{id};
            } elsif ( $meta{type} eq 'last_id_fixreplies' ) {
                $state{__last_id}{ $meta{username} }{__extras}{ $meta{id_type} } = $meta{id}
                  if $state{__last_id}{ $meta{username} }{__extras}{ $meta{id_type} } < $meta{id};
            }

        } elsif (s/^t:(tweet|dm|reply|search|search_once)\s+//x) {
            my %meta = &cache_to_meta($_, $1, [ qw/id ac ign reply_to_user reply_to_id nick topic created_at/ ]);

            if (exists $new_cache{ $meta{id} }) {
                # &debug("Skipping newly-cached $meta{id}");
                next;
            }
            $new_cache{ $meta{id} } = time;
            if (exists $tweet_cache{ $meta{id} }) {
                       # and (not $retweeted_id{$username} or not $retweeted_id{$username}{ $meta{id} });
                # &debug("Skipping cached $meta{id}");
                next;
            }

            my %line_attribs = &meta_to_line(\%meta);
            push @lines, { %line_attribs };

            if ( $meta{type} eq 'search' ) {
                if ( exists $state{__last_id}{ $meta{username} }{__search}{ $meta{topic} }
                        and $meta{id} > $state{__last_id}{ $meta{username} }{__search}{ $meta{topic} } ) {
                    $state{__last_id}{ $meta{username} }{__search}{ $meta{topic} } = $meta{id};
                }
            } elsif ( $meta{type} eq 'search_once' ) {
                delete $search_once{ $meta{username} }->{ $meta{topic} };
            }

        } elsif (s/^t:(friend|block)\s+//) {
            my $type = $1;
            my %meta = &cache_to_meta($_, $type, [ qw/ac nick epoch/ ]);
            if ($is_update and not defined $types_per_user{$meta{username}}{$type}) {
                if ($type eq 'friend') {
                    $friends{$meta{username}} = ();
                } elsif ($type eq 'block') {
                    $blocks{$meta{username}} = ();
                }
                $types_per_user{$meta{username}}{$type} = 1;
            }
            if ($type eq 'friend') {
                $nicks{$meta{nick}} = $friends{$meta{username}}{$meta{nick}} = $meta{epoch};
            } elsif ($type eq 'block') {
                $blocks{$meta{username}}{$meta{nick}} = $meta{epoch};
            }

        } else {
            &notice(['error'], "invalid: $_");
        }
    }

    if (defined $fh) {
        # file was opened, so we tried to parse...
        close $fh;

        # make sure the pid is removed from the waitpid list
        Irssi::pidwait_remove($child_pid);

        # and that we don't leave any zombies behind, somehow
        waitpid( -1, WNOHANG );

        &debug("new last_poll    = $last_poll{__poll}",
               "new last_poll_id = " . Dumper( $state{__last_id} ));
        if ($first_call and not $settings{force_first}) {
            &debug("First call, not printing updates");
        } else {
            &write_lines(\@lines, 1);
        }

        unlink $filename or warn "Failed to remove $filename: $!" unless &debug();

        # commit the pending cache lines to the actual cache, now that
        # we've printed our output
        for my $updated_id (keys %new_cache) {
            $tweet_cache{$updated_id} = $new_cache{$updated_id};
        }

        # keep enough cached tweets, to make sure we don't show duplicates
        for my $loop_id ( keys %tweet_cache ) {
            next if $tweet_cache{$loop_id} >= $last_poll{__poll} - 3600;
            delete $tweet_cache{$loop_id};
        }

        if (not $got_errors) {
            $failstatus        = 0;
            &save_state();
        }

        if ($is_update) {
            $first_call        = 0;
            $update_is_running = 0;
        }
        return;
    }

    # get here only if failed

    if ( $attempts_to_go > 0 ) {
        Irssi::timeout_add_once( $wait_time, 'monitor_child',
            [ $filename, $attempts_to_go - 1, $wait_time, $is_update ] );
    } else {
        &debug("Giving up on polling $filename");
        Irssi::pidwait_remove($child_pid);
        waitpid( -1, WNOHANG );
        unlink $filename unless &debug();

        if (not $is_update) {
            &notice([ 'error' ], "Failed to get response.  Giving up.");
            return;
        }

        $update_is_running = 0 if $is_update;

        return unless $settings{notify_timeouts};

        my $since;
        if ( time - $last_poll{__poll} < 24 * 60 * 60 ) {
            my @time = localtime($last_poll{__poll});
            $since = sprintf( "%d:%02d", @time[ 2, 1 ] );
        } else {
            $since = scalar localtime($last_poll{__poll});
        }

        if ( $failstatus < 2 and time - $last_poll{__poll} > 60 * 60 ) {
            &notice([ 'error' ],
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
#            &ccrap(
#                q{     v  v        v},
#                q{     |  |  v     |  v},
#                q{     | .-, |     |  |},
#                q{  .--./ /  |  _.---.| },
#                q{   '-. (__..-"       \\},
#                q{      \\          a    |},
#                q{       ',.__.   ,__.-'/},
#                q{         '--/_.'----'`}
#            );
            $failstatus = 2;
        }

        if ( $failstatus == 0 and time - $last_poll{__poll} < 600 ) {
            &notice([ 'error' ],"Haven't been able to get updated tweets since $since");
            $failstatus = 1;
        }
    }
}

sub write_lines {
    my $lines_ref       = shift;
    my $want_extras     = shift;
    my $want_ymd_suffix = shift;
    my $ymd_color = $irssi_to_mirc_colors{ $settings{ymd_color} };
    my @date_now = localtime();
    my $ymd_now = sprintf('%04d-%02d-%02d', $date_now[5]+1900, $date_now[4]+1, $date_now[3]);
    my $old_tf;
    #	&debug("line: " . Dumper $lines_ref);
    foreach my $line (@$lines_ref) {
        my $line_want_extras = $want_extras;
        my $win_name = &window( $line->{type}, $line->{username}, $line->{nick}, $line->{topic} );
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
        if (defined $line->{ignoring}) {
            next if not $settings{debug};
            $line->{text} = "\cC$irssi_to_mirc_colors{'%b'}IGNORED\cO " . $line->{text};
            if ($settings{debug_win_name} ne '' ) {
                $win_name = $settings{debug_win_name};
            } else {
                $win_name = '(status)';
                $line->{text} = "%g[$IRSSI{name}] %n " . $line->{text};
            }
            $line_want_extras = 0;
        } elsif ($want_ymd_suffix) {
            $ymd_suffix = " \cC$ymd_color$ymd\cO" if $ymd_now ne $ymd;
        } elsif (not defined $last_ymd{wins}{$win_name}
                  or $last_ymd{wins}{$win_name}->{ymd} ne $ymd) {
            Irssi::window_find_name($win_name)->printformat(MSGLEVEL_PUBLIC, 'twirssi_new_day', $ymd, '');
            $last_ymd{wins}{$win_name}->{ymd} = $ymd;
        }
        my $ts = DateTime->from_epoch( epoch => $line->{epoch}, time_zone => $local_tz
                                                    )->strftime($settings{timestamp_format});
        if (not defined $old_tf) {
            $old_tf = Irssi::settings_get_str('timestamp_format');
        }
        Irssi::command("^set timestamp_format $ts");
        Irssi::window_find_name($win_name)->printformat(
            @print_opts, &hilight( $line->{text} ) . $ymd_suffix
        );
        if ($line_want_extras) {
            &write_log($line, $win_name, \@date);
            &write_channels($line, \@date);
        }
    }
    # recall timestamp format
    if (defined $old_tf) {
        Irssi::command("^set timestamp_format $old_tf");
        &debug((0+@$lines_ref) . " lines, pre-ts: " . $old_tf);
    }
}

sub write_channels {
    my $line = shift;
    my $date_ref = shift;
    my %msg_seen;
    for my $type ($line->{type}, 'sender', '*') {
        next unless defined $state{__channels}{$type};
        for my $tag (($type eq 'sender' ? $line->{nick}
                                        : ($line->{type} =~ /search/ ? $line->{topic}
                                                                     : $line->{username})),
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
        push @logs, "Day changed to $ymd" if $ymd ne '';
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
        if ( open my $fh, '>', $file ) {
            print $fh JSON::Any->objToJson( \%state );
            close $fh;
        } else {
            &notice([ 'error' ],"Failed to write state to $file: $!");
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
                print $fh 't:debug +', substr(time, -3), ' ', $sub_line, "\n";
            } elsif ($settings{debug_win_name} ne '') {
                my $dbg_win = $settings{debug_win_name};
                $dbg_win = $settings{window} if not &ensure_window($dbg_win);
                Irssi::window_find_name($dbg_win)->print(
                    $sub_line, MSGLEVEL_PUBLIC );
            } else {
                print "[$IRSSI{name}] ", $sub_line;
            }
        }
    }
    return 1;
}

sub notice {
    my ( $type, $tag, $fh );
    if ( ref $_[0] ) {
        ( $type, $tag, $fh ) = @{ shift @_ };
    }
    foreach my $msg (@_) {
        if (defined $fh) {
            for my $sub_line (split("\n", $msg)) {
                print $fh "t:$type ", $sub_line, "\n" if $sub_line ne '';
            }
        } else {
            my $col = '%G';
            my $win_level = MSGLEVEL_PUBLIC;
            my $win;
            if ($tag eq '_tw_in_Win') {
                $win = Irssi::active_win();
            } elsif ($type eq 'crap') {
                $win = Irssi::window_find_name(&window());
                $col = '%R';
                $win_level = MSGLEVEL_CLIENTCRAP;
            } else {
                $win = Irssi::window_find_name(&window( $type, $tag ));
            }

            if ($type eq 'error') {
                $win->printformat(MSGLEVEL_PUBLIC, 'twirssi_error', $msg);
            } else {
                $win->print("${col}***%n $msg", $win_level );
            }
        }
    }
}

sub update_away {
    my $data = shift;

    if ( $data !~ /\@\w/ and $data !~ /^[dD] / ) {
        my $server = Irssi::server_find_tag( $settings{bitlbee_server} );
        if ($server) {
            $server->send_raw("away :$data");
            return 1;
        } else {
            &notice([ 'error' ], "Can't find bitlbee server.",
                "Update bitlbee_server or disable tweet_to_away" );
            return 0;
        }
    }

    return 0;
}

sub too_long {
    my $data     = shift;
    my $alert_to = shift;

    if ( length $data > 140 ) {
        &notice( $alert_to,
            "Tweet too long (" . length($data) . " characters) - aborted" )
          if defined $alert_to;
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
        &notice( ["error", $username], "Unknown username $username" );
        return;
    }

    return $username;
}

sub logged_in {
    my $obj = shift;
    unless ($obj) {
        &notice( ["error"],
            "Not logged in!  Use /twitter_login username" );
        return 0;
    }

    return 1;
}

sub sig_complete {
    my ( $complist, $window, $word, $linestart, $want_space ) = @_;

    my $cmdchars = quotemeta Irssi::settings_get_str('cmdchars');

    if ($linestart =~ s@^ ( [$cmdchars] (?:twitter|twirssi|tweet|dm|retweet) \w* ) _as $@$1$2@x
            or grep { $linestart =~ m{^ [$cmdchars] $_ (?:_as\s+\S+)? $}x } @{ $completion_types{'account'} }) {
        # '*_as' expects account
        $word =~ s/^@//;
        @$complist = grep /^\Q$word/i, map { s/\@.*// and $_ } keys %twits;
        return;
    }

    if (grep { $linestart =~ m{^ [$cmdchars] $_ (?:_as\s+\S+)? $}x } @{ $completion_types{'tweet'} }) {
        # 'tweet' expects nick:num (we offer last num for each nick)
        $word =~ s/^@//;
        @$complist = map { "$_:$state{__indexes}{lc $_}" }
          sort { $nicks{$b} <=> $nicks{$a} }
            grep /^\Q$word/i, keys %{ $state{__indexes} };
    }

    if (grep { $linestart =~ m{^ [$cmdchars] $_ (?:_as\s+\S+)? $}x } @{ $completion_types{'nick'} }) {
        # 'nick' expects a nick
        $word =~ s/^@//;
        push @$complist, grep /^\Q$word/i,
          sort { $nicks{$b} <=> $nicks{$a} } keys %nicks;
    }

    if (     $linestart =~ m{^ [$cmdchars] retweet_to (?:_as\s+\S+)? \s+ \S+ $}x) {
        @$complist = grep /^\Q$word/i, map { "-$_->{tag}" } Irssi::servers();
        return;
    } elsif ($linestart =~ m{^ [$cmdchars] retweet_to (?:_as\s+\S+)? \s+ \S+ \s+ -\S+ $}x) {
        @$complist = grep /^\Q$word/i, qw/ -channel -nick /;
        return;
    } elsif ($linestart =~ m{^ [$cmdchars] retweet_to (?:_as\s+\S+)? \s+ \S+ \s+ -(\S+) \s+ -channel $}x) {
        my $lc_tag = lc $1;
        @$complist = map { $_->{name} }
                         grep { $_->{name} =~ /^\Q$word/i and lc $_->{server}->{tag} eq $lc_tag }
                             Irssi::channels();
        return;
    }

    # anywhere in line...
    if (grep { $linestart =~ m{^ [$cmdchars] $_ (?:_as\s+\S+)? }x } @{ $completion_types{'re_nick'} }) {
        # 're_nick' can have @nick anywhere
        my $prefix = $word =~ s/^@//;
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
    my $do_add = shift;	# first run, want to add, too
    my @changed_stgs = ();

    foreach my $setting (@settings_defn) {
        my $setting_changed = 0;
        my $stg_type .= '_' . ($setting->[2] eq 'b' ? 'bool'
                                        : $setting->[2] eq 'i' ? 'int'
                                                : $setting->[2] eq 's' ? 'str' : '');
        if ($stg_type eq '_') {
            if ($do_add) {
                print        "ERROR: Bad opt '$setting->[2]' for $setting->[0]";
            } else {
                &notice( ["error"], "Bad opt '$setting->[2]' for $setting->[0]" );
            }
            next;
        }

        my $stg_type_fn;
        if ($do_add) {
            $stg_type_fn = 'Irssi::settings_add' . $stg_type;	# settings_add_str, settings_add_int, settings_add_bool
            no strict 'refs';
            $settings{ $setting->[0] } = &$stg_type_fn( $IRSSI{name}, $setting->[1], $setting->[3] );
        }

        my $prev_stg;
        {
            $prev_stg = $settings{ $setting->[0] };
            $stg_type_fn = 'Irssi::settings_get' . $stg_type;	# settings_get_str, settings_get_int, settings_get_bool
            no strict 'refs';
            $settings{ $setting->[0] } = &$stg_type_fn( $setting->[1] );
        }
        if ($setting->[2] eq 's') {
            my $pre_proc = $setting->[4];
            my $trim = 1;
            my $norm_user = 0;
            my $is_list = 0;
            while (defined $pre_proc and $pre_proc ne '') {
                if ($pre_proc =~ s/^lc(?:,|$)//) {
                    $settings{$setting->[0]} = lc $settings{$setting->[0]};
                } elsif ($pre_proc =~ s/^list{(.)}(?:,|$)//) {
                    my $re = $1;
                    $re = qr/\s*$re\s*/ if $trim;
                    if ($settings{$setting->[0]} eq '') {
                        $settings{$setting->[0]} = [ ];
                    } else {
                        $settings{$setting->[0]} = [ split($re, $settings{$setting->[0]}) ];
                    }
                    $is_list = 1;
                } elsif ($pre_proc =~ s/^norm_user(?:,|$)//) {
                    $norm_user = 1;
                } elsif ($do_add) {
                    print        "ERROR: Bad opt pre-proc '$pre_proc' for $setting->[0]";
                } else {
                    &notice( ["error"], "Bad opt pre-proc '$pre_proc' for $setting->[0]" );
                }
                if ($norm_user) {
                    my @normed = ();
                    for my $to_norm ($is_list ? @{ $settings{$setting->[0]} } : $settings{$setting->[0]} ) {
                        next if $to_norm eq '';
&debug($setting->[0] . ' to_norm {' . $to_norm . '}');
                        push @normed, &normalize_username($to_norm, 1);
                    }
                    $is_list = 1;
                    $settings{$setting->[0]} = ($is_list ? \@normed : $normed[0]);
                }
            }
            if (Dumper($prev_stg) ne Dumper($settings{ $setting->[0] })) {
                $setting_changed = 1;
            }
        } elsif ($prev_stg != $settings{ $setting->[0] }) {
            $setting_changed = 1;
        }
        push @changed_stgs, $setting->[0] if $setting_changed and not $do_add;
        if ($setting_changed or $do_add) {
            if ($setting->[0] eq 'poll_interval'
                    or $setting->[0] eq 'poll_schedule' ) {
                &ensure_updates();
            }
        }
    }
    &debug('changed settings: ' . join(', ', @changed_stgs)) if @changed_stgs;

    &ensure_logfile($settings{window});
    &debug("Settings changed ($do_add):" . Dumper \%settings);
}

sub ensure_logfile() {
    my $win_name = shift;
    return unless $settings{logging};
    my $new_logfile = Irssi::settings_get_str('autolog_path');
    return if $new_logfile eq '';
    $new_logfile =~ s/^~/$ENV{HOME}/;
    $new_logfile = strftime($new_logfile, localtime());
    $new_logfile =~ s/\$(tag\b|\{tag\})/$IRSSI{name}/g;
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
        &notice( ["error"], "Failed to append to $new_logfile: $!" );
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

    my $hhmm;
    foreach my $tuple ( @{ $settings{poll_schedule} } ) {
        if ( $tuple =~ /^(\d{4})-(\d{4}):(\d+)$/ ) {
            $hhmm = sprintf('%02d%02d', (localtime())[2,1]) if not defined $hhmm;
            my($range_from, $range_to, $poll_val) = ($1, $2, $3);
            if ( ( $hhmm ge $range_from and $hhmm lt $range_to )
                or ( $range_from gt $range_to
                    and ( $hhmm ge $range_from or $hhmm lt $range_to ) )
               ) {
                $poll = $poll_val;
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
    if ( ( $settings{always_shorten} or &too_long($data) ) and $provider ) {
        my @args;
        if ( $provider eq 'Bitly' ) {
            @args[ 1, 2 ] = split ',', $settings{url_args}, 2;
            unless ( @args == 3 ) {
                &notice([ 'crap' ],
                    "WWW::Shorten::Bitly requires a username and API key.",
                    "Set short_url_args to username,API_key or change your",
                    "short_url_provider."
                );
                return &make_utf8($data);
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

    return &make_utf8($data);
}

sub normalize_username {
    my $user      = shift;
    my $non_login = shift;
    return '' if $user eq '';

    my ( $username, $service ) = split /\@/, lc($user), 2;
    if ($service) {
        $service = ucfirst $service;
    } else {
        $service = ucfirst lc $settings{default_service};
        unless ( $non_login or exists $twits{"$username\@$service"} ) {
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
    my $sname = lc(shift);
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
    if ((not defined $win or $settings{window_priority} eq 'sender')
            and defined $sname
            and defined $state{__windows}{'sender'}
            and defined $state{__windows}{'sender'}{$sname}) {
        $win = $state{__windows}{'sender'}{$sname};
    }
    $win = $settings{window} if not defined $win;
    if (not &ensure_window($win, '_tw_in_Win')) {
        $win = $settings{window};
    }

    # &debug("window($type, $uname, $sname, $topic) -> $win");
    return $win;
}

sub ensure_window {
    my $win = shift;
    my $using_win = shift;
    return $win if Irssi::window_find_name($win);
    &notice([ 'crap', $using_win ], "Creating window '$win'.");
    my $newwin = Irssi::Windowitem::window_create( $win, 1 );
    if (not $newwin) {
        &notice([ 'error', $using_win ], "Failed to create window $win!");
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

    return;
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
        'twirssi_error',       '%RERROR%n: $0',
        'twirssi_new_day',     'Day changed to $0',
    ]
);

$last_poll{__poll} = time - &get_poll_time;

&event_setup_changed(1);
if ( Irssi::window_find_name(window()) ) {
    Irssi::command_bind( "dm",                         "cmd_direct" );
    Irssi::command_bind( "dm_as",                      "cmd_direct_as" );
    Irssi::command_bind( "tweet",                      "cmd_tweet" );
    Irssi::command_bind( "tweet_as",                   "cmd_tweet_as" );
    Irssi::command_bind( "retweet",                    "cmd_retweet" );
    Irssi::command_bind( "retweet_as",                 "cmd_retweet_as" );
    Irssi::command_bind( "retweet_to",                 "cmd_retweet_to_window" );
    Irssi::command_bind( "twitter_broadcast",          "cmd_broadcast" );
    Irssi::command_bind( "twitter_info",               "cmd_info" );
    Irssi::command_bind( "twitter_user",               "cmd_user" );
    Irssi::command_bind( "twitter_reply",              "cmd_reply" );
    Irssi::command_bind( "twitter_reply_as",           "cmd_reply_as" );
    Irssi::command_bind( "twitter_login",              "cmd_login" );
    Irssi::command_bind( "twitter_logout",             "cmd_logout" );
    Irssi::command_bind( "twitter_search",             "cmd_search" );
    Irssi::command_bind( "twitter_dms",                "cmd_dms" );
    Irssi::command_bind( "twitter_dms_as",             "cmd_dms_as" );
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
    Irssi::command_bind( "twirssi_wipe",               "cmd_wipe" );
    Irssi::command_bind( "bitlbee_away",               "update_away" );
    if ( $settings{use_reply_aliases} ) {
        Irssi::command_bind( "reply",    "cmd_reply" );
        Irssi::command_bind( "reply_as", "cmd_reply_as" );
    }
    Irssi::command_bind(
        "twirssi_dump",
        sub {
            &debug( "twits: ", join ", ",
              map { "u: $_\@" . ref($twits{$_}) } keys %twits );
            &debug( "selected: $user\@$defservice" );
            &debug( "friends: ", Dumper \%friends );
            &debug( "blocks: ", Dumper \%blocks );
            &debug( "nicks: ",   join ", ", sort keys %nicks );
            &debug( "searches: ", join(';  ', map { $state{__last_id}{$_}{__search} and "$_ : " . join(', ', keys %{ $state{__last_id}{$_}{__search} }) } keys %{ $state{__last_id} } ));
            &debug( "windows: ",  Dumper \%{ $state{__windows} } );
            &debug( "channels: ",  Dumper \%{ $state{__channels} } );
            &debug( "settings: ",  Dumper \%settings );
            &debug( "last poll: ", Dumper \%last_poll );
            if ( open my $fh, '>', "/tmp/$IRSSI{name}.cache.txt" ) {
                print $fh Dumper \%tweet_cache;
                close $fh;
                &notice([ 'crap' ], "cache written out to /tmp/$IRSSI{name}.cache.txt");
            }
            if ( open my $fh, '>', "$settings{dump_store}" ) {
                print $fh Dumper \%state;
                close $fh;
                &notice([ 'crap' ], "state written out to $settings{dump_store}");
            }
        }
    );
    Irssi::command_bind(
        "twirssi_version",
        sub {
            &notice(
                # ["error"],
                "$IRSSI{name} v$VERSION; "
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
                return $state{__last_id}{ &normalize_username($nick) }{__sent} unless defined $num;
                return $state{__ids}{$nick}[$num];
            }
        )
    );
    Irssi::command_bind(
        "twitter_fav",
        &gen_cmd(
            "/twitter_fav <username:id>",
            "create_favorite",
            sub { &notice( ["tweet"], "Tweet favorited." ); },
            sub {
                my ( $nick, $num ) = split ':', lc $_[0], 2;
                return $state{__last_id}{ &normalize_username($nick) }{__sent} unless defined $num;
                return $state{__ids}{$nick}[$num];
            }
        )
    );
    Irssi::command_bind(
        "twitter_unfav",
        &gen_cmd(
            "/twitter_unfav <username:id>",
            "destroy_favorite",
            sub { &notice( ["tweet"], "Tweet un-favorited." ); },
            sub {
                my ( $nick, $num ) = split ':', lc $_[0], 2;
                return $state{__last_id}{ &normalize_username($nick) }{__sent} unless defined $num;
                return $state{__ids}{$nick}[$num];
            }
        )
    );
    Irssi::command_bind(
        "twitter_follow",
        &gen_cmd(
            "/twitter_follow [-w] <username>",
            "create_friend",
            sub {
                &notice( ["tweet", "$user\@$defservice"],
                         "Following $_[0]" );
                $nicks{ $_[0] } = time;
            },
            sub {
                &cmd_set_window("sender $_[0] $_[0]", $_[1], $_[2])
                        if $_[0] =~ s/^\s*-w\s+// and $_[0] ne '';
                return $_[0];
            }
        )
    );
    Irssi::command_bind(
        "twitter_unfollow",
        &gen_cmd(
            "/twitter_unfollow <username>",
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

    %completion_types = (
        'account' => [
            'twitter_switch',
        ],
        'tweet' => [
            'retweet',
            'retweet_to',
            'twitter_delete',
            'twitter_fav',
            'twitter_info',
            'twitter_reply',
            'twitter_unfav',
        ],
        'nick' => [
            'dm',
            'twitter_block',
            'twitter_add_follow_extra',
            'twitter_del_follow_extra',
            'twitter_follow',
            'twitter_spam',
            'twitter_unblock',
            'twitter_unfollow',
            'twitter_user',
            'twitter_dms',	# here for twitter_dms_as
        ],
        're_nick' => [
            'dm',
            'retweet',
            'tweet',
        ],
    );
    push @{ $completion_types{'tweet'} }, 'reply' if $settings{use_reply_aliases};

    Irssi::signal_add_last( 'complete word' => \&sig_complete );

    &notice(
        "  %Y<%C(%B^%C)%N                   TWIRSSI v%R$VERSION%N",
        "   %C(_(\\%N           http://twirssi.com/ for full docs",
        "    %Y||%C `%N Log in with /twitter_login, send updates with /tweet"
    );

    my $file = $settings{replies_store};
    if ( $file and -r $file ) {
        if ( open( my $fh, '<', $file ) ) {
            local $/;
            my $json = <$fh>;
            close $fh;
            eval {
                my $ref = JSON::Any->jsonToObj($json);
                %state = %$ref;
                # fix legacy vulnerable ids
                for (grep !/^__\w+$/, keys %state) { $state{__ids}{$_} = $state{$_}; delete $state{$_}; }
                # # remove legacy broken searches (without service name)
                # map { /\@/ or delete $state{__searches}{$_} } keys %{$state{__searches}};
                # convert legacy/broken window tags (without @service, or unnormalized)
                for my $type (keys %{$state{__windows}}) {
                    next if $type eq 'search' or $type eq 'sender';
                    for my $tag (keys %{$state{__windows}{$type}}) {
                        next if $tag eq 'default';
                        my $new_tag = &normalize_username($tag);
                        next if -1 == index($new_tag, '@') or $new_tag eq $tag;
                        $state{__windows}{$type}{$new_tag} = $state{__windows}{$type}{$tag};
                        delete $state{__windows}{$type}{$tag};
                    }
                }
                my $num = keys %{ $state{__indexes} };

                # remove buggy subscriptions without service
                foreach my $account (keys %{$state{__searches}}) {
                    if ($account !~ /@/) {
                         delete $state{__searches}->{$account};
                    }
                }

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
            &notice(["error"],
                "Failed to load WWW::Shorten::$provider - either clear",
                "short_url_provider or install the CPAN module"
            );
        }
    }

    if ( @{ $settings{usernames} } ) {
        &cmd_login();
        &ensure_updates(15) if keys %twits;
    }

} else {
    Irssi::active_win()
      ->print( "Create a window named "
          . $settings{window}
          . " or change the value of twitter_window.  Then, reload $IRSSI{name}." );
}

# vim: set sts=4 expandtab:
