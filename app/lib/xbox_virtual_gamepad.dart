/// An experimental, page-scoped virtual gamepad bridge for the official
/// Xbox Remote Play web client. Inputs are exposed via the browser Gamepad
/// API; the Microsoft site may reject synthetic controllers or use iframes.
/// Installing the bridge is not confirmation of a remote console connection.
class XboxVirtualGamepad {
  static const buttonA = 0;
  static const buttonB = 1;
  static const buttonX = 2;
  static const buttonY = 3;
  static const view = 8;
  static const menu = 9;
  static const up = 12;
  static const down = 13;
  static const left = 14;
  static const right = 15;
  static const guide = 16;

  static const validButtons = <int>{
    buttonA, buttonB, buttonX, buttonY, view, menu,
    up, down, left, right, guide,
  };

  /// Evaluate on xbox.com only; never evaluate on a Microsoft sign-in domain.
  /// The page receives inputs only while this app is in the foreground.
  static const bootstrap = r'''
(function () {
  if (window.__tapTetherVirtualGamepad) return 'installed';
  var buttons = Array.from({length:17}, function() {
    return {pressed:false, touched:false, value:0};
  });
  var pad = {
    id:'TapTether Xbox Virtual Gamepad (PoC)',
    index:0, connected:true, mapping:'standard',
    axes:[0,0,0,0], buttons:buttons,
    timestamp:performance.now(),
    hapticActuators:[], vibrationActuator:null
  };
  var original = typeof navigator.getGamepads === 'function'
      ? navigator.getGamepads.bind(navigator) : function(){return []};
  var api = {
    button:function(index, pressed) {
      if (!Number.isInteger(index) || index < 0 || index >= 17) return false;
      var value = pressed ? 1 : 0;
      buttons[index].pressed = pressed;
      buttons[index].touched = pressed;
      buttons[index].value = value;
      pad.timestamp = performance.now();
      return true;
    },
    releaseAll:function() {
      buttons.forEach(function(button) {
        button.pressed = false;
        button.touched = false;
        button.value = 0;
      });
      pad.axes.fill(0);
      pad.timestamp = performance.now();
    },
    test:function() {
      try {
        var current = navigator.getGamepads();
        return current && current.length && current[0] === pad;
      } catch (_) { return false; }
    }
  };
  try {
    Object.defineProperty(navigator, 'getGamepads', {
      configurable:true,
      value:function() {
        var originalPads = [];
        try { originalPads = Array.from(original() || []); } catch (_) {}
        originalPads[0] = pad;
        return originalPads;
      }
    });
    if (!api.test()) return 'unsupported';
    window.__tapTetherVirtualGamepad = api;
    try {
      window.dispatchEvent(new Event('gamepadconnected'));
    } catch (_) {}
    window.addEventListener('pagehide', function(){ api.releaseAll(); });
    window.addEventListener('blur', function(){ api.releaseAll(); });
    return 'installed';
  } catch (_) { return 'unsupported'; }
})();
''';

  static String buttonScript(int button, bool pressed) {
    if (!validButtons.contains(button)) {
      throw ArgumentError.value(button, 'button', 'Unsupported Xbox button');
    }
    return '(function(){const pad=window.__tapTetherVirtualGamepad;'
      'return pad ? pad.button($button,${pressed ? 'true' : 'false'})'
      ' : false;})();';
  }

  static const releaseScript =
      '(function(){window.__tapTetherVirtualGamepad?.releaseAll();})();';

  static bool isMicrosoftXboxPage(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.scheme != 'https') return false;
    return parsed.host == 'xbox.com' || parsed.host == 'www.xbox.com';
  }
}
