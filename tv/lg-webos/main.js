(function () {
  'use strict';
  var count = 0;
  var button = document.getElementById('test');
  var headline = document.getElementById('headline');
  var detail = document.getElementById('detail');
  function update() {
    count += 1;
    headline.textContent = 'LG remote input received';
    detail.textContent = 'Button activations: ' + count + '. The webOS app is running locally.';
  }
  button.addEventListener('click', update);
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Enter' || event.keyCode === 13) {
      event.preventDefault(); update();
    }
  });
  button.focus();
}());
