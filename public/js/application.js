(function() {
  $('a.xx').on("click", function() {
    $(this).popover('toggle');
  })
  $("img.lazy").lazyload({effect : "show"});
})();
