/// 通用结果类型：仓储/服务层统一返回 `AppResult`，避免裸抛异常与 null 语义不清。
///
/// 语义与老项目一致（sealed 枚举风格，`fold` 分发）；失败带可读消息。
library;

/// 泛型结果：成功携带 [AppSuccess.value]，失败携带 [AppFailure.message]。
sealed class AppResult<T> {
  const AppResult();

  /// 双向分发（穷尽匹配由 sealed 保证）。
  R fold<R>({
    required R Function(AppSuccess<T> success) onSuccess,
    required R Function(AppFailure<T> failure) onFailure,
  }) {
    return switch (this) {
      final AppSuccess<T> success => onSuccess(success),
      final AppFailure<T> failure => onFailure(failure),
    };
  }

  /// [fold] 的别名，语义更贴近用途。
  R when<R>({
    required R Function(T value) onSuccess,
    required R Function(String message) onFailure,
  }) =>
      fold(
        onSuccess: (success) => onSuccess(success.value),
        onFailure: (failure) => onFailure(failure.message),
      );

  /// 是否为成功。
  bool get isSuccess => this is AppSuccess<T>;

  /// 成功值；失败时为 null。
  ///
  /// 注意：当 [T] 为可空类型时，"成功且值为 null" 与 "失败" 无法区分，
  /// 请配合 [isSuccess] 使用，或改用 [requireValue]。
  T? get valueOrNull => switch (this) {
        final AppSuccess<T> success => success.value,
        final AppFailure<T> _ => null,
      };

  /// 成功时返回 [value]；失败时抛出 [StateError]（携带失败原因）。
  ///
  /// 替代 `valueOrNull!` 裸解包：空安全且保留错误信息。
  T requireValue() => switch (this) {
        final AppSuccess<T> success => success.value,
        final AppFailure<T> failure =>
          throw StateError('AppResult 为失败：${failure.message}'),
      };
}

/// 成功结果。
class AppSuccess<T> extends AppResult<T> {
  const AppSuccess(this.value);

  final T value;

  /// 值相等：按 [value] 比较（与项目值类型模型约定一致）。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSuccess && runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => 'AppSuccess(value: $value)';
}

/// 失败结果；[message] 为可读的失败原因（供提示/日志）。
class AppFailure<T> extends AppResult<T> {
  const AppFailure(this.message);

  final String message;

  /// 值相等：按 [message] 比较。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppFailure && runtimeType == other.runtimeType &&
          message == other.message;

  @override
  int get hashCode => Object.hash(runtimeType, message);

  @override
  String toString() => 'AppFailure(message: $message)';
}
