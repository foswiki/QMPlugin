# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# QMPlugin is Copyright (C) 2019-2021 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html

package Foswiki::Plugins::QMPlugin::Handler::Merge;

use strict;
use warnings;

use Error qw(:try);
use Foswiki::Func ();
use Foswiki::Plugins::QMPlugin ();
use Foswiki::Plugins::QMPlugin::Utils;

use constant TRACE => 0; # toggle me

sub handle {
  my $command = shift;

  _writeDebug("called handle()");

  my $state = $command->getSource->getNet->getState();
  my $web = $state->getWeb();
  my $topic = $state->getTopic();

  throw Error::Simple("source topic $web.$topic does not exist")
    unless Foswiki::Func::topicExists($web, $topic);

  my $origin = $state->deleteProp("origin");
  $state->updateMeta();
  my $meta = $state->getMeta();

  my $origWeb;
  my $origTopic;
  my $origMeta;

  my $core = Foswiki::Plugins::QMPlugin::getCore();
  
  if (defined $origin) {
    ($origWeb, $origTopic) = Foswiki::Func::normalizeWebTopicName($web, $origin);

    throw Error::Simple("origin does not exist anymore")
      unless Foswiki::Func::topicExists($origWeb, $origTopic);

    ($origMeta) = Foswiki::Func::readTopic($origWeb, $origTopic);

    # move meta back to origin
    moveTopic($meta, $origMeta);

  } else {

    # temporarily rename
    $origWeb = $web;
    $origTopic = $topic;
    $topic = $topic . 'Copy' . time();

    _writeDebug("... renaming to $web.$topic");

    $meta = renameTopic($meta, $topic);

    # get original creator 
    my ($date, $origAuthor) = Foswiki::Func::getRevisionInfo($web, $topic, 1);
    $origAuthor = Foswiki::Func::getCanonicalUserID($origAuthor);
    _writeDebug("... origAuthor=$origAuthor");

    ($origMeta) = Foswiki::Func::readTopic($origWeb, $origTopic);

    # move meta back to origin
    moveTopic($meta, $origMeta,
      author => $origAuthor,
    );
  }

  _writeDebug("redirecting to $origWeb.$origTopic");
  throw Foswiki::Plugins::QMPlugin::Redirect(Foswiki::Func::getScriptUrlPath($origWeb, $origTopic, "view"));

  _writeDebug("done merge");
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::Merge - $_[0]\n";
}

1;


