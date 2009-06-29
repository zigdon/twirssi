<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
	"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">

<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head>
	<title>Twirssi: a twitter script for irssi</title>
	<style type="text/css" media="all">

	code {
		font-size: medium;
	}
	
	body {
		font: 0.8em arial, helvetica, sans-serif;
	}
	
    #header ul {
		list-style: none;
		padding: 0;
		margin: 0;
    }
    
	#header li {
		float: left;
		border: 1px solid white;
		margin: 0;
		font-weight: bold;
		font-size: larger;
		border-left-width: 0;
    }
    
	#header a {
		text-decoration: none;
		display: block;
		background: #70a0f0;
		padding: 0.24em 1em;
		color: white;
		width: 8em;
		text-align: center;
    }

    	#header a:visited {
		color: white;
	}
	
	#header a:hover {
		background: #3c68e5;
	}
	
	#header #selected {
	}
	
	#header #selected a {
		position: relative;
		background: white;
		color: black;
	}
	
	#content {
		clear: both;
		padding: 0.5em 1em;

	}
	
	h1 {
		margin: 0;
		padding: 0 0 1em 0;
	}

	</style>
	
</head>

<body bgcolor="#80a0ff">



<p id="title" height="150">
	<a href="index.php"><img src="twirssibird.png" alt="Twirssi logo" style="float:left;margin-right:5px" border="0"/></a>
	<font size="6" color="white"><b>Twirssi</b></font>
	<font size="5"><div style="text-indent:1em;color:#3c68e5">a twitter script for irssi</div></font>
</p>

<div id="header">
	<ul>
		<?php
			$about = $installing = $using = $history = "";
			if (isset($_GET['installing'])) {
				$installing = "id=\"selected\"";
				$content = "installing.html";
			} elseif (isset($_GET['using'])) {
				$using = "id=\"selected\"";
				$content = "using.html";
			} elseif (isset($_GET['history'])) {
				$history = "id=\"selected\"";
				$content = "history.html";
			} elseif (isset($_GET['tweets'])) {
				$tweets = "id=\"selected\"";
				$content = "tweets.html";
			} elseif (isset($_GET['merch'])) {
				$content = "merch.html";
			} else {
				$about = "id=\"selected\"";
				$content = "about.html";
			}
		?>
		<li <?=$about?> style="border-left-width: 1px"><a href="index.php">About</a></li>
		<li <?=$installing?>><a href="?installing">Installing</a></li>
		<li <?=$using?>><a href="?using">Using</a></li>
		<li <?=$history?>><a href="?history">Version History</a></li>
		<li <?=$tweets?>><a href="?tweets">Recent Tweets</a></li>
	</ul>
</div>


<div id="content" style="background:white">
	<p>
	<?=file_get_contents($content)?>
	</p>
</div>

<script type="text/javascript">
var gaJsHost = (("https:" == document.location.protocol) ? "https://ssl." : "http://www.");
document.write(unescape("%3Cscript src='" + gaJsHost + "google-analytics.com/ga.js' type='text/javascript'%3E%3C/script%3E"));
</script>
<script type="text/javascript">
try {
    var pageTracker = _gat._getTracker("UA-190820-2");
    pageTracker._trackPageview();
} catch(err) {}</script>
</body>
</html>

