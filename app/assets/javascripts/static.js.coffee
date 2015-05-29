# Place all the behaviors and hooks related to the matching controller here.
# All this logic will automatically be available in application.js.
# You can use CoffeeScript in this file: http://coffeescript.org/

formatNumberWithCommaDelimiter = (number) ->
  Math.ceil(number).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",")

animateNumber = (element, target_count, duration) ->
  jQuery(counter: 0).animate { counter: target_count - 40 },
    duration: duration
    easing: "easeInOutQuint"
    step: ->
      element.text formatNumberWithCommaDelimiter(@counter)
    complete: ->
      jQuery(counter: target_count - 40).animate { counter: (target_count) },
        duration: 400
        easing: "easeOutQuint"
        step: ->
          element.text formatNumberWithCommaDelimiter(@counter)
          return
      return
  return

$ ->
  metricsInview = new (Waypoint.Inview)(
    element: $('.metric-box')[0]
    enter: (direction) ->
      $(".metric-box strong").each (index) ->
        $target_count = parseInt($(this).text().replace(/\,/g, ''))
        animateNumber($(this), $target_count, 300 + index * 200) if $target_count > 0
      # only run this once
      this.destroy()
  )
