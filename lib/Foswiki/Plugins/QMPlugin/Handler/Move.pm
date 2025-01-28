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

package Foswiki::Plugins::QMPlugin::Handler::Move;

use strict;
use warnings;

use Error qw(:try);
use Foswiki::Func ();
use Foswiki::Plugins::QMPlugin::Utils qw(:all);

use constant TRACE => 0; # toggle me

sub handle {
  my ($command, $state) = @_;

  _writeDebug("called handle()");

  my $params = $command->getParams();
  my $meta = $state->getMeta();
  my $web = $state->getWeb();
  my $topic = $params->{_DEFAULT} || $params->{topic} || $state->getTopic();

  my $doReassign = 1;
  if ($params->{topic}) {
    ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);
    ($meta) = Foswiki::Func::readTopic($web, $topic);
    $doReassign = 0;
  }
  return unless $meta->existsInStore;

  my ($toWeb, $toTopic) = Foswiki::Func::normalizeWebTopicName($params->{toweb} || $web, $params->{totopic} || $params->{to} || $topic);
  _writeDebug("toWeb=$toWeb, toTopic=$toTopic");

  $toTopic = expandAUTOINC($toWeb, $toTopic);
  die "no toTopic" unless defined $toTopic;

  my ($toMeta) = Foswiki::Func::readTopic($toWeb, $toTopic);
  _writeDebug("moving $web.$topic to $toWeb.$toTopic");

  throw Error::Simple("Access denied") unless $toMeta->haveAccess("CHANGE");

  if ($toMeta->existsInStore) {
    throw Error::Simple("Topic already exists") unless Foswiki::Func::isTrue($params->{overwrite});
    copyTopic($meta, $toMeta);
    $meta->removeFromStore();
  } else {
    $meta->move($toMeta);
  }

  $state->reassign($toMeta) if $doReassign;

  my $url = $params->{redirect};
  if (defined $url) {

    unless ($url =~ /^https?:\/\// || $url =~ /^\//) {
      my ($origWeb, $origTopic) = Foswiki::Func::normalizeWebTopicName($web, $params->{redirect});
      _writeDebug("redirecting to $origWeb.$origWeb");
      $url = Foswiki::Func::getScriptUrlPath($origWeb, $origTopic, "view");
    }

    $state->getCore->redirectUrl($url);
  }

  _writeDebug("done move");
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::Move - $_[0]\n";
}

1;



