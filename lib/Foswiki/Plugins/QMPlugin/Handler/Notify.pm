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

package Foswiki::Plugins::QMPlugin::Handler::Notify;

use strict;
use warnings;

use Error qw(:try);
use Foswiki::Func ();
use Foswiki::Plugins::QMPlugin();

use constant TRACE => 0; # toggle me

sub afterSaveHandler {
  my $command = shift;

  _writeDebug("called afterSaveHandler()");

  my $state = $command->getSource->getNet->getState();
  
  return $state->sendNotification();
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::Notify - $_[0]\n";
}

1;
