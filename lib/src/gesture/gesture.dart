import 'dart:math' as math;

import 'package:extended_image/src/editor/editor_utils.dart';
import 'package:extended_image/src/gesture/utils.dart';

import 'package:extended_image/src/image/raw_image.dart';
import 'package:extended_image/src/utils.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../typedef.dart';
import 'page_view/gesture_page_view.dart';
import 'slide_page.dart';

Map<Object?, GestureDetails?> _gestureDetailsCache =
    <Object?, GestureDetails?>{};

///clear the gesture details
void clearGestureDetailsCache() {
  _gestureDetailsCache.clear();
}

bool _defaultCanScaleImage(GestureDetails? details) => true;

extension _Sqrt on Offset {
  Offset pow(double exp) => Offset(math.pow(dx.abs(), exp) * dx.sign, math.pow(dy.abs(), exp) * dy.sign);
}

extension _Direction on Offset {
  bool get pointsUp {
    final double d = direction / math.pi;
    return d >= 0.25 && d <= 0.75;
  } 
  bool get pointsDown {
    final double d = direction / math.pi;
    return d <= -0.25 && d >= -0.75;
  } 
  bool get pointsLeft => direction.abs() <= (0.25 * math.pi);
  bool get pointsRight => direction.abs() >= (0.75 * math.pi);
}

/// scale idea from https://github.com/flutter/flutter/blob/master/examples/layers/widgets/gestures.dart
/// zoom image
class ExtendedImageGesture extends StatefulWidget {
  const ExtendedImageGesture(
    this.extendedImageState, {
    this.imageBuilder,
    CanScaleImage? canScaleImage,
    Key? key,
  })  : canScaleImage = canScaleImage ?? _defaultCanScaleImage,
        super(key: key);
  final ExtendedImageState extendedImageState;
  final ImageBuilderForGesture? imageBuilder;
  final CanScaleImage canScaleImage;
  @override
  ExtendedImageGestureStateImage createState() => ExtendedImageGestureStateImage();
}

class ExtendedImageGestureWidget extends StatefulWidget {
  const ExtendedImageGestureWidget({
    required this.child,
    this.heroBuilderForSlidingPage,
    this.initGestureConfigHandler,
    this.fit = BoxFit.contain,
    this.layoutInsets = EdgeInsets.zero,
    CanScaleImage? canScaleImage,
    super.key
  }) : canScaleImage = canScaleImage ?? _defaultCanScaleImage;
  final Widget child;
  final HeroBuilderForSlidingPage? heroBuilderForSlidingPage;
  final GestureConfig Function()? initGestureConfigHandler;
  final BoxFit fit;
  final EdgeInsets layoutInsets;
  final CanScaleImage canScaleImage;
  @override
  ExtendedImageGestureStateWidget createState() => ExtendedImageGestureStateWidget();
}


typedef ExtendedImageGestureState = ExtendedImageGestureStateBase<StatefulWidget>;
abstract class ExtendedImageGestureStateBase<T extends StatefulWidget> extends State<T>
    with TickerProviderStateMixin {
  ///details for gesture
  GestureDetails? _gestureDetails;
  late Offset _normalizedOffset;
  double? _startingScale;
  late Offset _startingOffset;
  late Boundary _startingBoundary;
  Offset? _pointerDownPosition;
  final Map<int, PointerDeviceKind> _pointerDownKinds = <int, PointerDeviceKind>{};
  late GestureAnimation _gestureAnimation;
  GestureConfig? _gestureConfig;
  ExtendedImageGesturePageViewState? _pageViewState;
  ExtendedImageSlidePageState? get extendedImageSlidePageState;
  double? _passedThroughPageViewGestureSign;

  GestureDetails? get gestureDetails => _gestureDetails;

  set gestureDetails(GestureDetails? value) {
    if (mounted) {
      setState(() {
        _gestureDetails = value;
        _gestureConfig?.gestureDetailsIsChanged?.call(_gestureDetails);
      });
    }
  }

  Object? get _currentImageKey;
  GestureConfig? _makeGestureConfig();
  VoidCallback? _makeOnDoubleTap();
  HeroBuilderForSlidingPage? get _heroBuilderForSlidingPage;
  bool _canScaleImage(GestureDetails? details);
  Widget _buildImpl();

  GestureConfig? get imageGestureConfig => _gestureConfig;

  Offset? get pointerDownPosition => _pointerDownPosition;

  @override
  Widget build(BuildContext context) {
    if (_gestureConfig!.cacheGesture) {
      _gestureDetailsCache[_currentImageKey] =
          _gestureDetails;
    }

    Widget image = _buildImpl();

    image = GestureDetector(
      onScaleStart: handleScaleStart,
      onScaleUpdate: handleScaleUpdate,
      onScaleEnd: handleScaleEnd,
      onDoubleTap: _makeOnDoubleTap(),
      child: image,
      behavior: _gestureConfig?.hitTestBehavior,
    );

    image = Listener(
      child: image,
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerUp,
      onPointerPanZoomStart: _handlePointerPanZoomStart,
      onPointerPanZoomEnd: _handlePointerPanZoomEnd,
      onPointerCancel: _handlePointerCancel,
      onPointerSignal: _handlePointerSignal,
      behavior: _gestureConfig!.hitTestBehavior,
    );

    return image;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageViewState = null;
    if (_gestureConfig!.inPageView) {
      _pageViewState =
          context.findAncestorStateOfType<ExtendedImageGesturePageViewState>();
      _pageViewState?.extendedImageGestureState = this;
    }
  }

  @override
  void didUpdateWidget(T oldWidget) {
    super.didUpdateWidget(oldWidget);
    _initGestureConfig();
    _pageViewState = null;
    if (_gestureConfig!.inPageView) {
      _pageViewState =
          context.findAncestorStateOfType<ExtendedImageGesturePageViewState>();
      _pageViewState?.extendedImageGestureState = this;
    }
  }

  @override
  void dispose() {
    _gestureAnimation.stop();
    _gestureAnimation.dispose();
    _pageViewState?.extendedImageGestureStates.remove(this);
    super.dispose();
  }

  void handleDoubleTap({double? scale, Offset? doubleTapPosition}) {
    doubleTapPosition ??= _pointerDownPosition;
    scale ??= _gestureConfig!.initialScale;
    //scale = scale.clamp(_gestureConfig.minScale, _gestureConfig.maxScale);
    handleScaleStart(ScaleStartDetails(focalPoint: doubleTapPosition!));
    handleScaleUpdate(ScaleUpdateDetails(
      focalPoint: doubleTapPosition,
      scale: scale / _startingScale!,
      focalPointDelta: Offset.zero,
    ));
    if (scale < _gestureConfig!.minScale || scale > _gestureConfig!.maxScale) {
      handleScaleEnd(ScaleEndDetails());
    }
  }

  @override
  void initState() {
    super.initState();
    _initGestureConfig();
  }

  void reset() {
    _gestureConfig = _makeGestureConfig() ?? GestureConfig();

    gestureDetails = GestureDetails(
      totalScale: _gestureConfig!.initialScale,
      offset: Offset.zero,
      initialAlignment: _gestureConfig!.initialAlignment,
    );
  }

  void slide() {
    if (mounted) {
      setState(() {
        _gestureDetails!.slidePageOffset = extendedImageSlidePageState?.offset;
      });
    }
  }

  void _handlePointerDown(PointerDownEvent pointerDownEvent) {
    _pointerDownKinds[pointerDownEvent.pointer] = pointerDownEvent.kind;
    _pointerDownPosition = pointerDownEvent.position;
    _gestureAnimation.stop();

    _pageViewState?.extendedImageGestureState = this;
  }

  void _handlePointerUp(PointerUpEvent pointerUpEvent) {
    _pointerDownKinds.remove(pointerUpEvent.pointer);
  }

  void _handlePointerCancel(PointerCancelEvent pointerCancelEvent) {
    _pointerDownKinds.remove(pointerCancelEvent.pointer);
  }

  void _handlePointerPanZoomStart(PointerPanZoomStartEvent pointerPanZoomStartEvent) {
    _pointerDownKinds[pointerPanZoomStartEvent.pointer] = pointerPanZoomStartEvent.kind;
  }

  void _handlePointerPanZoomEnd(PointerPanZoomEndEvent pointerPanZoomEndEvent) {
    _pointerDownKinds.remove(pointerPanZoomEndEvent.pointer);
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && event.kind == PointerDeviceKind.mouse) {
      handleScaleStart(ScaleStartDetails(focalPoint: event.position));
      final double dy = event.scrollDelta.dy;
      final double dx = event.scrollDelta.dx;
      handleScaleUpdate(ScaleUpdateDetails(
          focalPoint: event.position,
          scale: 1.0 +
              _reverseIf((dy.abs() > dx.abs() ? dy : dx) *
                  _gestureConfig!.speed /
                  1000.0),
          focalPointDelta: Offset.zero));
      handleScaleEnd(ScaleEndDetails());
    }
  }

  void handleScaleEnd(ScaleEndDetails details) {
    if (extendedImageSlidePageState != null &&
        extendedImageSlidePageState!.isSliding) {
      extendedImageSlidePageState!.endSlide(details);
      return;
    }

    if (_pageViewState != null && _pageViewState!.isDraging) {
      _pageViewState!.onDragEnd(
        DragEndDetails(
          velocity: _pageViewState!.widget.scrollDirection == Axis.horizontal
              ? Velocity(
                  pixelsPerSecond:
                      Offset(details.velocity.pixelsPerSecond.dx, 0))
              : Velocity(
                  pixelsPerSecond:
                      Offset(0, details.velocity.pixelsPerSecond.dy)),
          primaryVelocity:
              _pageViewState!.widget.scrollDirection == Axis.horizontal
                  ? details.velocity.pixelsPerSecond.dx
                  : details.velocity.pixelsPerSecond.dy,
        ),
      );
      return;
    }

    //animate back to maxScale if gesture exceeded the maxScale specified
    if (_gestureDetails!.totalScale!.greaterThan(_gestureConfig!.maxScale)) {
      final double velocity =
          (_gestureDetails!.totalScale! - _gestureConfig!.maxScale) /
              _gestureConfig!.maxScale;

      _gestureAnimation.animationScale(
          _gestureDetails!.totalScale, _gestureConfig!.maxScale, velocity);
      return;
    }

    //animate back to minScale if gesture fell smaller than the minScale specified
    if (_gestureDetails!.totalScale!.lessThan(_gestureConfig!.minScale)) {
      final double velocity =
          (_gestureConfig!.minScale - _gestureDetails!.totalScale!) /
              _gestureConfig!.minScale;

      _gestureAnimation.animationScale(
          _gestureDetails!.totalScale, _gestureConfig!.minScale, velocity);
      return;
    }

    if (_gestureDetails!.actionType == ActionType.pan) {
      // get magnitude from gesture velocity
      final double magnitude = details.velocity.pixelsPerSecond.distance;

      // do a significant magnitude
      if (magnitude.greaterThanOrEqualTo(minMagnitude)) {
        final Offset direction = (details.velocity.pixelsPerSecond /
            minMagnitude).pow(0.75) * 0.2 *
            _gestureConfig!.inertialSpeed * math.pow(_gestureDetails?.totalScale ?? 1, 2/3).toDouble();
        _gestureAnimation.animationOffset(
            _gestureDetails!.offset, _gestureDetails!.offset! + direction);
      }
    }
  }

  void handleScaleStart(ScaleStartDetails details) {
    _gestureAnimation.stop();
    _normalizedOffset = (details.focalPoint - _gestureDetails!.offset!) /
        _gestureDetails!.totalScale!;
    _startingScale = _gestureDetails!.totalScale;
    _startingOffset = details.focalPoint;
    _startingBoundary = _gestureDetails!.boundary;
  }

  void handleScaleUpdate(ScaleUpdateDetails details) {
    if (extendedImageSlidePageState != null &&
        details.scale == 1.0 &&
        (
          (_gestureDetails!.totalScale ?? 1) <= 1 ||
          (_startingBoundary.top && ((details.focalPoint - _startingOffset).pointsUp || (_gestureDetails?.slidePageOffset?.dy ?? 0) > 0)) ||
          (_startingBoundary.bottom && ((details.focalPoint - _startingOffset).pointsDown || (_gestureDetails?.slidePageOffset?.dy ?? 0) < 0))
        ) &&
        _pageViewState?.isDraging != true &&
        _gestureDetails!.userOffset &&
        _gestureDetails!.actionType == ActionType.pan) {
      final Offset totalDelta = details.focalPointDelta;
      bool updateGesture = false;
      if (!extendedImageSlidePageState!.isSliding) {
        if (totalDelta.dx != 0 &&
            totalDelta.dx.abs().greaterThan(totalDelta.dy.abs())) {
          if (_gestureDetails!.computeHorizontalBoundary) {
            if (totalDelta.dx > 0) {
              updateGesture = _gestureDetails!.boundary.left;
            } else {
              updateGesture = _gestureDetails!.boundary.right;
            }
          } else {
            updateGesture = true;
          }
        }
        if (totalDelta.dy != 0 &&
            totalDelta.dy.abs().greaterThan(totalDelta.dx.abs())) {
          if (_gestureDetails!.computeVerticalBoundary) {
            if (totalDelta.dy < 0) {
              updateGesture = _gestureDetails!.boundary.bottom;
            } else {
              updateGesture = _gestureDetails!.boundary.top;
            }
          } else {
            updateGesture = true;
          }
        }
      } else {
        updateGesture = true;
      }
      final double delta = (details.focalPoint - _startingOffset).distance;
      if (delta.greaterThan(minGesturePageDelta) && updateGesture) {
        extendedImageSlidePageState!.slide(
          details.focalPointDelta,
          extendedImageGestureState: this,
        );
      }
    }
    else if (extendedImageSlidePageState != null && extendedImageSlidePageState!.isSliding) {
      extendedImageSlidePageState!.endSlide(ScaleEndDetails());
    }

    if (extendedImageSlidePageState != null &&
        extendedImageSlidePageState!.isSliding) {
      return;
    }

    // totalScale > 1 and page view is starting to move
    if (_pageViewState != null) {
      final ExtendedImageGesturePageViewState pageViewState = _pageViewState!;

      final Axis axis = pageViewState.widget.scrollDirection;
      final bool movePage = _pageViewState!.isDraging ||
          ((_pointerDownKinds.length == 1) &&
              details.scale == 1 &&
              (
                (_startingBoundary.left && (details.focalPoint - _startingOffset).pointsLeft) ||
                (_startingBoundary.right && (details.focalPoint - _startingOffset).pointsRight)
              ) &&
              _gestureDetails!.movePage(details.focalPointDelta, axis));

      if (movePage && switch (_passedThroughPageViewGestureSign) {
        final double sign => sign == _pageViewState!.totalDrag.sign,
        null => true
      }) {
        if (!pageViewState.isDraging) {
          pageViewState
              .onDragDown(DragDownDetails(globalPosition: details.focalPoint));
          pageViewState.onDragStart(
              DragStartDetails(globalPosition: details.focalPoint));
          _passedThroughPageViewGestureSign = (axis == Axis.horizontal ? details.focalPointDelta.dx : details.focalPointDelta.dy).sign;
          //assert(!pageViewState.isDraging);
        }
        Offset delta = details.focalPointDelta;
        delta =
            axis == Axis.horizontal ? Offset(delta.dx, 0) : Offset(0, delta.dy);

        pageViewState.onDragUpdate(DragUpdateDetails(
          globalPosition: details.focalPoint,
          delta: delta,
          primaryDelta: (axis == Axis.horizontal ? delta.dx : delta.dy),
        ));

        return;
      }
      else if (_passedThroughPageViewGestureSign != null) {
        // Kill the old gesture
        pageViewState.onDragEnd(DragEndDetails(primaryVelocity: 0));
        _passedThroughPageViewGestureSign = null;
        // Reset the _normalizedOffset to avoid a jump in case dy has changed while in passed-through state
        _normalizedOffset = (details.focalPoint - _gestureDetails!.offset!) / _gestureDetails!.totalScale!;
        _startingOffset = details.focalPoint;
      }
    }
    final double? scale = _canScaleImage(_gestureDetails)
        ? clampScale(
            _startingScale! * details.scale * _gestureConfig!.speed,
            _gestureConfig!.animationMinScale,
            _gestureConfig!.animationMaxScale)
        : _gestureDetails!.totalScale;

    //Round the scale to three points after comma to prevent shaking
    //scale = roundAfter(scale, 3);
    //no more zoom

    final Offset offset = (details.focalPoint * _gestureConfig!.speed) -
        _normalizedOffset * scale!;

    if (mounted &&
        (offset != _gestureDetails!.offset ||
            scale != _gestureDetails!.totalScale)) {
      gestureDetails = GestureDetails(
          offset: offset,
          totalScale: scale,
          gestureDetails: _gestureDetails,
          actionType: details.scale != 1.0 ? ActionType.zoom : ActionType.pan);
    }
  }

  void _initGestureConfig() {
    final double? initialScale = _gestureConfig?.initialScale;
    final InitialAlignment? initialAlignment = _gestureConfig?.initialAlignment;
    _gestureConfig = _makeGestureConfig() ?? GestureConfig();

    if (_gestureDetails == null ||
        initialScale != _gestureConfig!.initialScale ||
        initialAlignment != _gestureConfig!.initialAlignment) {
      _gestureDetails = GestureDetails(
        totalScale: _gestureConfig!.initialScale,
        offset: Offset.zero,
        initialAlignment: _gestureConfig!.initialAlignment,
      );
    }

    if (_gestureConfig!.cacheGesture) {
      final GestureDetails? cache =
          _gestureDetailsCache[_currentImageKey];
      if (cache != null) {
        _gestureDetails = cache;
      }
    }
    _gestureDetails ??= GestureDetails(
      totalScale: _gestureConfig!.initialScale,
      offset: Offset.zero,
    );

    _gestureAnimation = GestureAnimation(this, offsetCallBack: (Offset value) {
      gestureDetails = GestureDetails(
          offset: value,
          totalScale: _gestureDetails!.totalScale,
          gestureDetails: _gestureDetails);
    }, scaleCallBack: (double scale) {
      gestureDetails = GestureDetails(
          offset: _gestureDetails!.offset,
          totalScale: scale,
          gestureDetails: _gestureDetails,
          actionType: ActionType.zoom,
          userOffset: false);
    });
  }

  double _reverseIf(double scaleDetal) {
    if (_gestureConfig?.reverseMousePointerScrollDirection ?? false) {
      return -scaleDetal;
    } else {
      return scaleDetal;
    }
  }

  Widget wrapGestureWidget(
    Widget child, {
    BoxFit fit = BoxFit.contain,
    EdgeInsets layoutInsets = EdgeInsets.zero,
  }) {
    child = GestureWidgetLayout(
      fit: fit,
      layoutInsets: layoutInsets,
      gestureDetails: gestureDetails,
      child: child,
    );

    if (extendedImageSlidePageState != null) {
      child = _heroBuilderForSlidingPage?.call(child) ??
          child;
      if (extendedImageSlidePageState!.widget.slideType ==
          SlideType.onlyImage) {
        child = Transform.translate(
          offset: extendedImageSlidePageState!.offset,
          child: Transform.scale(
            scale: extendedImageSlidePageState!.scale,
            child: child,
          ),
        );
      }
    }

    return child;
  }
}

class ExtendedImageGestureStateImage extends ExtendedImageGestureStateBase<ExtendedImageGesture> {
  @override
  ExtendedImageSlidePageState? get extendedImageSlidePageState =>
      widget.extendedImageState.slidePageState;
  @override
  Object? get _currentImageKey => widget.extendedImageState.imageStreamKey;

  @override
  VoidCallback? _makeOnDoubleTap() =>
      (widget.extendedImageState.imageWidget.onDoubleTap != null) ? () => widget.extendedImageState.imageWidget.onDoubleTap!(this) : null;

  @override
  GestureConfig? _makeGestureConfig() =>
    widget.extendedImageState.imageWidget.initGestureConfigHandler?.call(widget.extendedImageState);

  @override
  HeroBuilderForSlidingPage? get _heroBuilderForSlidingPage =>
      widget.extendedImageState.imageWidget.heroBuilderForSlidingPage;

  @override
  bool _canScaleImage(GestureDetails? details) => widget.canScaleImage(details);
  
  @override
  Widget _buildImpl() {
    Widget image = ExtendedRawImage(
      image: widget.extendedImageState.extendedImageInfo?.image,
      width: widget.extendedImageState.imageWidget.width,
      height: widget.extendedImageState.imageWidget.height,
      scale: widget.extendedImageState.extendedImageInfo?.scale ?? 1.0,
      color: widget.extendedImageState.imageWidget.color,
      colorBlendMode: widget.extendedImageState.imageWidget.colorBlendMode,
      fit: widget.extendedImageState.imageWidget.fit,
      alignment: widget.extendedImageState.imageWidget.alignment,
      repeat: widget.extendedImageState.imageWidget.repeat,
      centerSlice: widget.extendedImageState.imageWidget.centerSlice,
      matchTextDirection:
          widget.extendedImageState.imageWidget.matchTextDirection,
      invertColors: widget.extendedImageState.invertColors,
      filterQuality: widget.extendedImageState.imageWidget.filterQuality,
      beforePaintImage: widget.extendedImageState.imageWidget.beforePaintImage,
      afterPaintImage: widget.extendedImageState.imageWidget.afterPaintImage,
      gestureDetails: _gestureDetails,
      layoutInsets: widget.extendedImageState.imageWidget.layoutInsets,
      rotate90DegreesClockwise: widget.extendedImageState.imageWidget.rotate90DegreesClockwise,
    );
    if (extendedImageSlidePageState != null) {
      image = _heroBuilderForSlidingPage?.call(image) ?? image;
      if (extendedImageSlidePageState!.widget.slideType ==
          SlideType.onlyImage) {
        image = Transform.translate(
          offset: extendedImageSlidePageState!.offset,
          child: Transform.scale(
            scale: extendedImageSlidePageState!.scale,
            child: image,
          ),
        );
      }
    }
    return widget.imageBuilder?.call(image, imageGestureState: this) ?? image;
  }
}

class ExtendedImageGestureStateWidget extends ExtendedImageGestureStateBase<ExtendedImageGestureWidget> {
  @override
  ExtendedImageSlidePageState? extendedImageSlidePageState;
  @override
  Object? get _currentImageKey => null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    extendedImageSlidePageState = context.findAncestorStateOfType<ExtendedImageSlidePageState>();
  }

  @override
  VoidCallback? _makeOnDoubleTap() => null;

  @override
  GestureConfig? _makeGestureConfig() => widget.initGestureConfigHandler?.call();

  @override
  HeroBuilderForSlidingPage? get _heroBuilderForSlidingPage =>
      widget.heroBuilderForSlidingPage;

  @override
  bool _canScaleImage(GestureDetails? details) => widget.canScaleImage(details);

  @override
  Widget _buildImpl() {
    return wrapGestureWidget(widget.child, fit: widget.fit, layoutInsets: widget.layoutInsets);
  }
}

class RenderGestureWidgetLayout extends RenderProxyBox {
  RenderGestureWidgetLayout({
    BoxFit fit = BoxFit.contain,
    GestureDetails? gestureDetails,
    EdgeInsets layoutInsets = EdgeInsets.zero,
    RenderBox? child,
  }) : _fit = fit,
       _gestureDetails = gestureDetails,
       _layoutInsets = layoutInsets,
       super(child);

  BoxFit _fit;
  set fit(BoxFit newValue) {
    if (_fit == newValue) {
      return;
    }
    _fit = newValue;
    markNeedsLayout();
  }

  GestureDetails? _gestureDetails;
  set gestureDetails(GestureDetails? newValue) {
    if (_gestureDetails == newValue) {
      return;
    }
    _gestureDetails = newValue;
    markNeedsLayout();
  }

  EdgeInsets _layoutInsets;
  set layoutInsets(EdgeInsets newValue) {
    if (_layoutInsets == newValue) {
      return;
    }
    _layoutInsets = newValue;
    markNeedsLayout();
  }

  // TODO(ianh): The intrinsic dimensions of this box are wrong.

  @override
  @protected
  Size computeDryLayout(BoxConstraints constraints) {
    if (child != null) {
      final Size childSize = child!.getDryLayout(const BoxConstraints());

      switch (_fit) {
        case BoxFit.scaleDown:
          final BoxConstraints sizeConstraints = constraints.loosen();
          final Size unconstrainedSize = sizeConstraints.constrainSizeAndAttemptToPreserveAspectRatio(childSize);
          return constraints.constrain(unconstrainedSize);
        case BoxFit.contain:
        case BoxFit.cover:
        case BoxFit.fill:
        case BoxFit.fitHeight:
        case BoxFit.fitWidth:
        case BoxFit.none:
          return constraints.constrainSizeAndAttemptToPreserveAspectRatio(childSize);
      }
    } else {
      return constraints.smallest;
    }
  }

  @override
  void performLayout() {
    if (child != null) {
      child!.layout(const BoxConstraints(), parentUsesSize: true);
      final Rect rect = _layoutInsets.deflateRect(Offset.zero & constraints.biggest);
      Rect destinationRect = getDestinationRect(
        rect: rect,
        inputSize: child!.size,
        fit: _fit
      );

      destinationRect = _gestureDetails?.calculateFinalDestinationRect(rect, destinationRect) ?? destinationRect;
      
      switch (_fit) {
        case BoxFit.scaleDown:
          final BoxConstraints sizeConstraints = constraints.loosen();
          final Size unconstrainedSize = sizeConstraints.constrainSizeAndAttemptToPreserveAspectRatio(child!.size);
          size = constraints.constrain(unconstrainedSize);
        case BoxFit.contain:
        case BoxFit.cover:
        case BoxFit.fill:
        case BoxFit.fitHeight:
        case BoxFit.fitWidth:
        case BoxFit.none:
          size = constraints.constrainSizeAndAttemptToPreserveAspectRatio(child!.size);
      }
      _clearPaintData();
    } else {
      size = constraints.smallest;
    }
  }

  bool? _hasVisualOverflow;
  Matrix4? _transform;

  /// {@macro flutter.material.Material.clipBehavior}
  ///
  /// Defaults to [Clip.none].
  Clip get clipBehavior => _clipBehavior;
  Clip _clipBehavior = Clip.none;
  set clipBehavior(Clip value) {
    if (value != _clipBehavior) {
      _clipBehavior = value;
      markNeedsPaint();
      markNeedsSemanticsUpdate();
    }
  }

  void _clearPaintData() {
    _hasVisualOverflow = null;
    _transform = null;
  }

  void _updatePaintData() {
    if (_transform != null) {
      return;
    }

    if (child == null) {
      _hasVisualOverflow = false;
      _transform = Matrix4.identity();
    } else {
      final Size childSize = child!.size;
      final Rect rect = _layoutInsets.deflateRect(Offset.zero & size);
      Rect destinationRect = getDestinationRect(
        rect: rect,
        inputSize: childSize,
        fit: _fit
      );
      destinationRect = _gestureDetails?.calculateFinalDestinationRect(rect, destinationRect) ?? destinationRect;
      final Rect sourceRect = Offset.zero & childSize;
      _hasVisualOverflow = sourceRect.width < childSize.width || sourceRect.height < childSize.height;
      final double scaleX = destinationRect.width / sourceRect.width;
      final double scaleY = destinationRect.height / sourceRect.height;
      print(destinationRect);
      assert(scaleX.isFinite && scaleY.isFinite);
      _transform = Matrix4.translationValues(destinationRect.left, destinationRect.top, 0.0)
        ..scale(scaleX, scaleY, 1.0)
        ..translate(-sourceRect.left, -sourceRect.top);
      assert(_transform!.storage.every((double value) => value.isFinite));
    }
  }

  TransformLayer? _paintChildWithTransform(PaintingContext context, Offset offset) {
    final Offset? childOffset = MatrixUtils.getAsTranslation(_transform!);
    if (childOffset == null) {
      return context.pushTransform(
        needsCompositing,
        offset,
        _transform!,
        super.paint,
        oldLayer: layer is TransformLayer ? layer! as TransformLayer : null,
      );
    } else {
      super.paint(context, offset + childOffset);
    }
    return null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || size.isEmpty || child!.size.isEmpty) {
      return;
    }
    _updatePaintData();
    assert(child != null);
    if (_hasVisualOverflow! && clipBehavior != Clip.none) {
      layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        _paintChildWithTransform,
        oldLayer: layer is ClipRectLayer ? layer! as ClipRectLayer : null,
        clipBehavior: clipBehavior,
      );
    } else {
      layer = _paintChildWithTransform(context, offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, { required Offset position }) {
    if (size.isEmpty || (child?.size.isEmpty ?? false)) {
      return false;
    }
    _updatePaintData();
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (BoxHitTestResult result, Offset position) {
        return super.hitTestChildren(result, position: position);
      },
    );
  }

  @override
  bool paintsChild(RenderBox child) {
    assert(child.parent == this);
    return !size.isEmpty && !child.size.isEmpty;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (!paintsChild(child)) {
      transform.setZero();
    } else {
      _updatePaintData();
      transform.multiply(_transform!);
    }
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(EnumProperty<BoxFit>('_fit', _fit));
    properties.add(DiagnosticsProperty<GestureDetails?>('_gestureDetails', _gestureDetails));
    properties.add(DiagnosticsProperty<EdgeInsets>('_layoutInsets', _layoutInsets));
  }
}

class GestureWidgetLayout extends SingleChildRenderObjectWidget {
  const GestureWidgetLayout({
    super.key,
    this.fit = BoxFit.contain,
    this.gestureDetails,
    this.layoutInsets = EdgeInsets.zero,
    super.child,
  });

  final BoxFit fit;
  final GestureDetails? gestureDetails;
  final EdgeInsets layoutInsets;

  @override
  RenderGestureWidgetLayout createRenderObject(BuildContext context) {
    return RenderGestureWidgetLayout(
      fit: fit,
      gestureDetails: gestureDetails,
      layoutInsets: layoutInsets
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderGestureWidgetLayout renderObject) {
    renderObject
      ..fit = fit
      ..gestureDetails = gestureDetails
      ..layoutInsets = layoutInsets;
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(EnumProperty<BoxFit>('fit', fit));
    properties.add(DiagnosticsProperty<GestureDetails?>('gestureDetails', gestureDetails));
    properties.add(DiagnosticsProperty<EdgeInsets>('layoutInsets', layoutInsets));
  }
}

class GestureWidgetDelegateFromRect extends SingleChildLayoutDelegate {
  GestureWidgetDelegateFromRect(this.destinationRect);

  final Rect destinationRect;
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return destinationRect.topLeft;
  }

  @override
  bool shouldRelayout(GestureWidgetDelegateFromRect oldDelegate) {
    return destinationRect != oldDelegate.destinationRect;
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.tight(destinationRect.size);
  }
}
