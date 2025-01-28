# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# QMPlugin is Copyright (C) 2019-2025 Michael Daum http://michaeldaumconsulting.com
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

package Foswiki::Plugins::QMPlugin::Handler::Fork;

use strict;
use warnings;

use Error qw(:try);
use Foswiki::Func ();
use Foswiki::Plugins::QMPlugin();
use Foswiki::Plugins::QMPlugin::Utils qw(:all);

use constant TRACE => 0; # toggle me

sub beforeSaveHandler {
  my ($command, $state) = @_;

  _writeDebug("called beforeSaveHandler()");

  my $params = $command->getParams();
  my $web = $state->getWeb();
  my $topic = $state->getTopic();

  throw Error::Simple("source topic $web.$topic does not exist")
    unless Foswiki::Func::topicExists($web, $topic);

  my $suffix = $params->{suffix} // 'Copy';
  throw Error::Simple("This topic already is a fork.")
    if $topic =~ /$suffix$/; 

  my $targetTopic = $topic . $suffix;
  throw Error::Simple("Fork already in progress.")
    if Foswiki::Func::topicExists($web, $targetTopic);

  $state->reroute($web, $targetTopic);
  
  _writeDebug("done fork");
}

sub afterSaveHandler {
  my $command = shift;

  _writeDebug("called afterSaveHandler()");

  my $state = $command->getSource->getNet->getState();
  my $meta = $state->getMeta();
  my $web = $state->getWeb();
  my $topic = $state->getTopic();

  my $origin = $state->prop("origin");
  my ($origWeb, $origTopic) = Foswiki::Func::normalizeWebTopicName($web, $origin);
  my ($origMeta) = Foswiki::Func::readTopic($origWeb, $origTopic);

  copyAttachments($origMeta, $meta);

  _writeDebug("redirecting to $web.$topic");
  $state->getCore->redirectUrl(Foswiki::Func::getScriptUrlPath($web, $topic, "view"));
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::Fork - $_[0]\n";
}

1;

