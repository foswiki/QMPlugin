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

package Foswiki::Plugins::QMPlugin::Handler::Copy;

use strict;
use warnings;

use Error qw(:try);
use Foswiki::Func ();
use Foswiki::Plugins::QMPlugin::Redirect();
use Foswiki::Plugins::QMPlugin::Utils;

use constant TRACE => 0; # toggle me

sub handle {
  my $command = shift;

  _writeDebug("called handle()");

  my $state = $command->getSource->getNet->getState();
  my $params = $command->getParams();
  my $web = $state->getWeb();
  my $topic = $state->getTopic();
  my $meta = $state->getMeta();

  my $targetWeb = $params->{web} || $web;
  my $targetTopic = $params->{topic} || $topic;
  ($targetWeb, $targetTopic) = Foswiki::Func::normalizeWebTopicName($targetWeb, $targetTopic);

  throw Error::Simple("cannot copy topic onto itself")
    unless $web ne $targetWeb || $topic ne $targetTopic;

  my ($targetMeta) = Foswiki::Func::readTopic($targetWeb, $targetTopic);

  throw Error::Simple("Access denied") unless $targetMeta->haveAccess("CHANGE");

  _writeDebug("copying to $targetWeb.$targetTopic");
  copyTopic($meta, $targetMeta);  

  _writeDebug("done copy");
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::Copy - $_[0]\n";
}

1;
