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

package Foswiki::Plugins::QMPlugin::Utils;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::Utils

This package exports a few operations on topics and attachments
to ease copying, moving and trashing them with ease. All functions
operate on Foswiki::Meta objects.

=cut

use strict;
use warnings;

use Exporter;
our @ISA = ('Exporter');
our @EXPORT = qw(
  trashTopic moveTopic copyTopic renameTopic 
  trashAttachments trashAttachment copyAttachments copyAttachment
);

use constant TRACE => 0; # toggle me

use Foswiki();
use Foswiki::Func ();
use Foswiki::Meta ();
use Foswiki::Plugins ();
use Foswiki::Plugins::QMPlugin ();

=begin TML

---++ ClassMethod trashTopic($meta)

moves a topic object to the trash web. see also Foswiki::UI::Rename

=cut

sub trashTopic {
  my $from = shift;

  my $targetWeb = $Foswiki::cfg{TrashWebName};
  my $targetTopic = $from->getPath();
  $targetTopic =~ s/[\/\.]//g;

  my $tmp = $targetTopic;
  my $n = 1;
  while (Foswiki::Func::topicExists($targetWeb, $targetTopic)) {
    $targetTopic = $tmp . $n;
    $n++;
  }

  my ($to) = Foswiki::Func::readTopic($targetWeb, $targetTopic);

  $from->move($to);
}

=begin TML

---++ ClassMethod trashAttachments($meta)

moves all attachments of a topic objects to the trash. see also Foswiki::UI::Rename

=cut

sub trashAttachments {
  my $from = shift;

  my ($trash) = Foswiki::Func::readTopic($Foswiki::cfg{TrashWebName}, 'TrashAttachment');

  foreach my $attachment ($from->find('FILEATTACHMENT')) {
    trashAttachment($from, $attachment, $trash);
  }
}

=begin TML

---++ ClassMethod trashAttachment($from, $attachment)

move a single attachment to the trash

=cut

sub trashAttachment {
  my ($from, $attachment, $trash) = @_;

  ($trash) = Foswiki::Func::readTopic($Foswiki::cfg{TrashWebName}, 'TrashAttachment')
    unless defined $trash;

  # from Foswiki::UI::Rename
  # look for a non-conflicting name in the trash web

  my $toAttachment = $attachment->{name};
  my $base = $toAttachment;
  my $ext = '';

  if ( $base =~ s/^(.*)(\..*?)$/$1_/ ) {
    $ext = $2;
  }

  my $n = 1;
  while ($trash->hasAttachment($toAttachment)) {
    $toAttachment = $base . $n . $ext;
    $n++;
  }

  $from->moveAttachment($attachment->{name}, $trash, new_name => $toAttachment);
}

=begin TML

---++ ClassMethod copyAttachments($from, $to)

moves all attachments from one topic to another.

=cut

sub copyAttachments {
  my ($from, $to) = @_;

  _writeDebug("called copyAttachments");

  foreach my $attachment ($from->find('FILEATTACHMENT')) {
    copyAttachment($from, $attachment, $to);
  }
}

=begin TML

---++ ClassMethod copyAttachment($from, $attachment, $to)

move a single attachment from one topic to another.

=cut

sub copyAttachment {
  my ($from, $attachment, $to) = @_;

  _writeDebug("called copyAttachment(attachment=$attachment->{name}, to=".$to->getPath().")");

  # NOT using copyAttachment as this will nuke revisions in the target
  # $from->copyAttachment($attachment, $to);


  my $fh = $from->openAttachment($attachment->{name}, "<");

  $to->attach(
    name => $attachment->{name},
    comment => $attachment->{comment},
    author => $attachment->{author},
    hide => $attachment->{attr} =~ /h/ ? 1:0,
    stream => $fh,
    dontlog => 1,
    notopicchange => 1,
    nohandlers => 1,
  );

  my $toAttachment = $to->get("FILEATTACHMENT", $attachment->{name});
  $toAttachment->{attr} = $attachment->{attr} if $toAttachment;
}

=begin TML

---++ ClassMethod copyTopic($from, $to)

copies the  one topic to another. Note that
this function only copies over the top revision of the source
topic, not the entire history. It thereby creates a new revision 
at the target topic. Attachments are copied over as well. However
attachments that don't exist at the source topic anymore are removed from
the target topic.

=cut

sub copyTopic {
  my $from = shift;
  my $to = shift;

  _writeDebug("copyTopic(from=".$from->getPath().", to=".$to->getPath().")");
  my %attachmentExists = ();
  $attachmentExists{$_->{name}} = 1 foreach $from->find('FILEATTACHMENT');

  my ($trash) = Foswiki::Func::readTopic($Foswiki::cfg{TrashWebName}, 'TrashAttachment');

  foreach my $attachment ($to->find('FILEATTACHMENT')) {
    trashAttachment($to, $attachment, $trash)
      unless $attachmentExists{$attachment->{name}};
  }

  $to->text($from->text() // '');
  $to->copyFrom($from);

  copyAttachments($from, $to);

  my $core = Foswiki::Plugins::QMPlugin::getCore();
  $core->saveMeta($to,
    ignorepermissions => 1,
    forcenewrevision => 1,
    @_
  );
}

=begin TML

---++ ClassMethod moveTopic($from, $to)

this function copies the source topic to the target
and then deletes the source topic afterwards.

=cut

sub moveTopic {
  my $from = shift;
  my $to = shift;

  copyTopic($from, $to, @_);
  trashTopic($from);
}

=begin TML

---++ ClassMethod renameTopic($from, $to)

rename/moves topic from one location to another.
Note that =$to= can either be a Foswiki::Meta object
or a topic name

=cut

sub renameTopic {
  my ($from, $toOrTopic) = @_;

  my $to;

  if (ref($toOrTopic)) {
    $to = $toOrTopic;
  } else {
    my ($web, $topic) = Foswiki::Func::normalizeWebTopicName($from->web, $toOrTopic);
    $to = Foswiki::Meta->new( $Foswiki::Plugins::SESSION, $web, $topic );
  }

  # rename it
  $from->move($to);

  return $to;
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::Utils - $_[0]\n";
}

1;
