# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# QMPlugin is Copyright (C) 2020-2025 Michael Daum http://michaeldaumconsulting.com
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

package Foswiki::Form::Qmworkflow;

use strict;
use warnings;

use Foswiki::Form::Topic ();
our @ISA = ('Foswiki::Form::Topic');

sub new {
  my $class = shift;

  my $this = $class->SUPER::new(@_);

  $this->{_formfieldClass} = 'foswikiQMWorkflow';

  # make sure we get the right things
  my $topicType = $this->param("TopicType") // "WorkflowDefinition";
  $this->param("TopicType", $topicType);

  return $this;
}

1;

