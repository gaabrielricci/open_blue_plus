import 'dart:async';

/// A stream that emits [current] on listen (unless it is null) and then every
/// event of [changes].
///
/// The subscription to [changes] is made synchronously on listen, right
/// after reading [current], so no change can slip in between (an `async*`
/// generator would only subscribe a few microtasks later, losing events
/// emitted in that window). The stream may be listened to several times;
/// every listener gets its own current value.
Stream<T> currentThen<T extends Object>(
        T? Function() current, Stream<T> changes) =>
    Stream<T>.multi((out) {
      final now = current();
      if (now != null) out.add(now);
      out.onCancel = changes.listen(out.add, onError: out.addError).cancel;
    });
