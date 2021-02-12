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

package Foswiki::Plugins::QMPlugin::JQuery;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::JQuery

jQuery plugin to load the plugin's css and javascript assets

=cut

use strict;
use warnings;

use Foswiki::Plugins::JQueryPlugin::Plugin ();
our @ISA = qw( Foswiki::Plugins::JQueryPlugin::Plugin );

=begin TML

---++ ClassMethod new() -> $plugin

constructor for an object of this class

=cut

sub new {
    my $class = shift;
    my $session = shift || $Foswiki::Plugins::SESSION;

    my $this = $class->SUPER::new(
        $session,
        name          => 'QMPlugin',
        version       => '1.0',
        author        => 'Michael Daum',
        homepage      => 'http://foswiki.org/Extensions/QMPlugin',
        puburl        => '%PUBURLPATH%/%SYSTEMWEB%/QMPlugin',
        documentation => "$Foswiki::cfg{SystemWebName}.QMPlugin",
        css           => ['qmplugin.css'],
        javascript    => ['qmplugin.js'],
        dependencies  => ['form', 'pnotify', 'blockui', 'ui::dialog'],
        @_
    );

    return $this;
}

1;
