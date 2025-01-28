/*
 * QMPlugin 
 *
 * (c)opyright 2019-2025 Michael Daum http://michaeldaumconsulting.com
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details, published at
 * http://www.gnu.org/copyleft/gpl.html
 *
 */
"use strict";
jQuery(function($) {
  $(".qmAjaxForm").livequery(function() {
    var $this = $(this);

    $this
      .addClass("qmAjaxFormInited")
      .removeAttr("onsubmit")
      .ajaxForm({
        beforeSerialize: function() {
          if (typeof(StrikeOne) !== 'undefined') {
            StrikeOne.submit($this[0]);
          }
        }, 
        beforeSubmit: function() {
          $this.parents(".ui-dialog-content").first().dialog("close");
          $.blockUI({message:'<h1 class="i18n">Submitting ...</h1>'});
        },
        error: function(xhr) {
          var response = xhr.responseJSON;
          //console.log("response=",response);
          $.unblockUI();
          $.pnotify({
            type: "error",
            title: "Error",
            hide: 0,
            text: response.error.message
          });
        },
        success: function(response) {
          $.unblockUI();
          //console.log("result=",response.result);
          if (typeof(response.result.redirect) !== 'undefined') {
            window.location.href = response.result.redirect;
          } else {
            window.location.reload();
          }
        }
      });
   });

  $(".qmChangeStateForm").livequery(function() {
    var $form = $(this),
        $to = $form.find("input[name=to]"),
        iconMap = {
          "fa-circle-o": "fa-circle",
          "fa-square-o": "fa-square",
          "fa-send-o": "fa-send",
          "fa-thumbs-o-up": "fa-thumbs-up",
          "fa-thumbs-o-down": "fa-thumbs-down",
          "fa-file-o": "fa-file",
          "fa-file-text-o": "fa-file-text",
          "fa-heart-o": "fa-heart",
          "fa-arrow-circle-o-right": "fa-arrow-circle-right"
        };

    function toggleIcon (elem, type) {
      $.each(iconMap, function(key, val) {
        var from, to;
        if (type === 'check') {
          from = key;
          to = val;
        } else {
          from = val;
          to = key;
        }
        if (elem.is("."+from)) {
          elem.removeClass(from).addClass(to);
          return false;
        }
      });
    }

    function init() {
      var action, to;

      $form.find("input[type=radio]").each(function() {
        var $radio = $(this),
            $icon = $radio.parent().find(".jqIcon");

        if ($radio.is(":checked")) {
          toggleIcon($icon, "check");
          $radio.parent().addClass("qmSelected");
          to = $radio.data("to");
          action = $radio.val();
        } else {
          toggleIcon($icon, "uncheck");
          $radio.parent().removeClass("qmSelected");
        }
      });

      if (typeof(to) !== 'undefined' && to !== '') {
        $to.val(to);
        //console.log("selecting action=",action,"to=",to);
      }
    };

    init();

    $form.find("label").on("click", init);
  });
});
