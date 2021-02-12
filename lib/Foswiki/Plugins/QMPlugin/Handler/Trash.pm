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

package Foswiki::Plugins::QMPlugin::Handler::Trash;

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
  my $meta = $state->getMeta();
  my $web = $state->getWeb();
  my $origin = $state->prop("origin");

  my $topic = $params->{_DEFAULT} || $params->{topic};

  if ($params->{topic}) {
    ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);
    ($meta) = Foswiki::Func::readTopic($web, $topic);
  }

  trashTopic($meta);  

  if (defined $origin) {
    my ($origWeb, $origTopic) = Foswiki::Func::normalizeWebTopicName($web, $origin);
    _writeDebug("redirecting to $origWeb.$origWeb");
    throw Foswiki::Plugins::QMPlugin::Redirect(Foswiki::Func::getScriptUrlPath($origWeb, $origTopic, "view"));
  }

  _writeDebug("done trash");
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::Trash - $_[0]\n";
}

1;


