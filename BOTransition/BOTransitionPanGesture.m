//
//  BOTransitionPanGesture.m
//  BOTransition
//
//  Created by bo on 2020/11/13.
//  Copyright © 2020 bo. All rights reserved.
//

#import "BOTransitionPanGesture.h"

static UIEdgeInsets sf_common_contentInset(UIScrollView * __nonnull scrollView) {
    if (@available(iOS 11.0, *)) {
        return scrollView.adjustedContentInset;
    } else {
        return scrollView.contentInset;
    }
}

@interface BOTransitionPanGesture () <UIGestureRecognizerDelegate>

@property (nonatomic, assign) UIGestureRecognizerState originState;

@property (nonatomic, strong) NSMutableArray<NSValue *> *touchInfoAr;

@property (nonatomic, assign) BOTransitionGesSliceInfo initialDirectionInfo;
@property (nonatomic, assign) BOTransitionGesSliceInfo triggerDirectionInfo;
@property (nonatomic, assign) BOOL delayTrigger;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *otherSVRespondedDirectionRecord;

@property (nonatomic, assign) UIGestureRecognizerState transitionGesState;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *careOtherDic;

//保存正在响应手势的UIScrollView，对它们的状态进行检测来判断是否应该开始dismiss
@property (nonatomic, strong) NSMutableArray<UIScrollView *> *currPanScrollVAr;
@property (nonatomic, strong) NSMutableArray<NSValue *> *currPanScrollVSavOffsetAr;
@property (nonatomic, assign) BOOL beganWithOtherSVBounces;

@property (nonatomic, assign) BOTransitionPanGestureBrief lastGesBrief;
@property (nonatomic, assign) BOOL needsRecoverWhenTouchDown;

@property (nonatomic, strong) NSMutableArray<UIGestureRecognizer *> *otherGesWillExecSimultaneouslyStrategy;

//同时只接收和响应第一个touch的began、move、end、cancel
@property (nonatomic, strong) UITouch *currTouch;

@end

@implementation BOTransitionPanGesture

- (instancetype)initWithTransitionGesDelegate:(id<BOTransitionGestureDelegate>)transitionGesDelegate {
    self = [super initWithTarget:nil action:nil];
    if (self) {
        super.delegate = self;
        super.delaysTouchesBegan = NO;
        super.delaysTouchesEnded = NO;
        self.transitionGesDelegate = transitionGesDelegate;
    }
    return self;
}

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    return [self initWithTransitionGesDelegate:nil];
}

- (NSMutableDictionary *)userInfo {
    if (!_userInfo) {
        _userInfo = [NSMutableDictionary new];
    }
    return _userInfo;
}

- (CGPoint)velocityInCurrView {
    if (_touchInfoAr.count < 2) {
        return CGPointZero;
    }
    
    __block NSInteger lastptidx = -1;
    __block NSInteger remoteidx = -1;
    [_touchInfoAr enumerateObjectsWithOptions:NSEnumerationReverse
                                   usingBlock:^(NSValue * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (lastptidx < 0) {
            lastptidx = idx;
        } else if (remoteidx < 0) {
            remoteidx = idx;
        } else {
            CGFloat ptts = obj.CGRectValue.size.width;
            if (ptts > 0) {
                CGFloat lastts = self.touchInfoAr[lastptidx].CGRectValue.size.width;
                if (lastts <= 0) {
                    //失效
                    *stop = YES;
                }
                
                if (lastts - ptts > 0.16) {
                    //寻找结束
                    *stop = YES;
                } else {
                    remoteidx = idx;
                }
            } else {
                *stop = YES;
            }
        }
    }];
    
    CGPoint vel = CGPointZero;
    if (lastptidx >= 0
        && remoteidx >= 0
        && lastptidx != remoteidx) {
        CGRect lastptinfo = _touchInfoAr[lastptidx].CGRectValue;
        CGRect remoteptinfo = _touchInfoAr[remoteidx].CGRectValue;
        
        if (lastptinfo.size.width > 0 && remoteptinfo.size.width > 0) {
            CGFloat ptdur = lastptinfo.size.width - remoteptinfo.size.width;
            
            vel = CGPointMake((lastptinfo.origin.x - remoteptinfo.origin.x) / ptdur,
                              (lastptinfo.origin.y - remoteptinfo.origin.y) / ptdur);
        }
    }
    return vel;
}

- (void)reset {
    [super reset];
    [self innerReset];
}

- (void)innerReset {
    _currTouch = nil;
    _touchInfoAr = nil;
    
    switch (_originState) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            self.originState = UIGestureRecognizerStateCancelled;
            break;
        default:
            break;
    }
    
    _originState = UIGestureRecognizerStatePossible;
    _transitionGesState = UIGestureRecognizerStatePossible;
    
    [_otherGesWillExecSimultaneouslyStrategy removeAllObjects];
    //这个不用频繁释放了吧
    //    _otherGesWillExecSimultaneouslyStrategy = nil;
    
    _beganWithOtherSVBounces = NO;
    [self clearCurrSVRecord];
    
    if (_careOtherDic) {
        [_careOtherDic removeAllObjects];
    }
}

- (void)makeGesStateCanceledButCanRetryBegan {
    switch (_transitionGesState) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            self.transitionGesState = UIGestureRecognizerStateCancelled;
            break;
        default:
            break;
    }
    
    _transitionGesState = UIGestureRecognizerStatePossible;
    
    [_touchInfoAr removeAllObjects];
    
    [_currPanScrollVSavOffsetAr removeAllObjects];
    [_otherSVRespondedDirectionRecord removeAllObjects];
    _delayTrigger = NO;
    _beganWithOtherSVBounces = NO;
}

- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)preventingGestureRecognizer {
    if (preventingGestureRecognizer != self
        && [BOTransitionPanGesture isTransitonGes:preventingGestureRecognizer]) {
        return YES;
    }
    return NO;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (!_currTouch) {
        _currTouch = [touches anyObject];
        [self touchesDidChange:[NSSet setWithObject:_currTouch]
                         event:event state:UIGestureRecognizerStateBegan];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    if (_currTouch
        && [touches containsObject:_currTouch]) {
        [self touchesDidChange:[NSSet setWithObject:_currTouch] event:event state:UIGestureRecognizerStateChanged];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (_currTouch
        && ([touches containsObject:_currTouch] || 0 == touches.count)) {
        [self touchesDidChange:[NSSet setWithObject:_currTouch] event:event state:UIGestureRecognizerStateEnded];
        _currTouch = nil;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    if (_currTouch
        && ([touches containsObject:_currTouch] || 0 == touches.count)) {
        [self touchesDidChange:[NSSet setWithObject:_currTouch] event:event state:UIGestureRecognizerStateCancelled];
        _currTouch = nil;
    }
}

- (void)touchesDidChange:(NSSet<UITouch *> *)touches
                   event:(UIEvent *)event
                   state:(UIGestureRecognizerState)state {
    
    switch (state) {
        case UIGestureRecognizerStateBegan:
            if (!_touchInfoAr) {
                _touchInfoAr = [NSMutableArray new];
                
                [touches enumerateObjectsUsingBlock:^(UITouch * _Nonnull obj, BOOL * _Nonnull stop) {
                    for (UIView *theview = obj.view;
                         (theview != self.view && nil != theview);
                         theview = theview.superview) {
                        if ([theview isKindOfClass:[UIScrollView class]]) {
                            UIScrollView *scv = (UIScrollView *)theview;
                            if (scv.scrollEnabled &&
                                YES == scv.panGestureRecognizer.enabled) {
                                [self addCurrPanSV:scv];
                            }
                        } else if ([theview isKindOfClass:[UIControl class]]) {
                            if (theview.userInteractionEnabled
                                && [(UIControl *)theview isEnabled]) {
                                [self addCareOtherObj:(id)theview forKey:@"control"];
                            }
                        } else if ([theview isKindOfClass:[UITableViewCell class]]
                                   || [theview isKindOfClass:[UICollectionViewCell class]]) {
                            [self addCareOtherObj:(id)theview forKey:@"cell"];
                        } else if (theview.userInteractionEnabled
                                   && [theview.nextResponder isKindOfClass:[UINavigationController class]]) {
                            UINavigationController *thenc = (UINavigationController *)theview.nextResponder;
                            if (thenc.interactivePopGestureRecognizer) {
                                if (self.transitionGesDelegate
                                    && [self.transitionGesDelegate respondsToSelector:@selector(checkTransitionGes:otherTransitionGes:makeFail:)]) {
                                    NSInteger checkst =\
                                    [self.transitionGesDelegate checkTransitionGes:self
                                                                otherTransitionGes:thenc.interactivePopGestureRecognizer
                                                                          makeFail:YES];
                                    
                                    if (2 == checkst) {
                                        [self makeGestureStateCanceledOrFailed];
                                        return;
                                    }
                                }
                            }
                            
                            [self addCareOtherObj:(id)theview forKey:@"nc"];
                        }
                    }
                }];
                
                if ([self currPanSVInBounces]) {
                    _beganWithOtherSVBounces = YES;
                }
            } else {
                return;
            }
            
        case UIGestureRecognizerStateChanged: {
            if (_touchInfoAr) {
                UITouch *touch = [touches anyObject];
                CGPoint locpt = [touch locationInView:self.view];
                
                if (_touchInfoAr.count > 0 &&
                    CGPointEqualToPoint(_touchInfoAr.lastObject.CGRectValue.origin, locpt)) {
                    return;
                }
                
                [_touchInfoAr addObject:@((CGRect){locpt, [NSDate date].timeIntervalSince1970, 0})];
                
                if (_touchInfoAr.count > 6) {
                    [_touchInfoAr removeObjectAtIndex:1];
                }
                
                self.originState = state;
            }
        }
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            if (_touchInfoAr) {
                
                UITouch *touch = [touches anyObject];
                CGPoint locpt = [touch locationInView:self.view];
                [_touchInfoAr addObject:@((CGRect){locpt, [NSDate date].timeIntervalSince1970, 0})];
                
                if (_touchInfoAr.count > 3) {
                    [_touchInfoAr removeObjectAtIndex:1];
                }
                
                self.originState = state;
                
                self.state = UIGestureRecognizerStateFailed;
            }
        }
            break;
        default:
            break;
    }
}

- (void)setOriginState:(UIGestureRecognizerState)originState {
    if (_originState != originState
        || UIGestureRecognizerStateChanged == originState) {
        _originState = originState;
        
        BOOL hastranbegan = (UIGestureRecognizerStateBegan == _transitionGesState
                             || UIGestureRecognizerStateChanged == _transitionGesState);
        
        switch (originState) {
            case UIGestureRecognizerStateBegan: {
                if (_needsRecoverWhenTouchDown) {
                    NSNumber *shouldbegin;
                    if (self.transitionGesDelegate &&
                        [self.transitionGesDelegate respondsToSelector:@selector(boTransitionGesShouldAndWillBegin:subInfo:)]) {
                        shouldbegin =\
                        [self.transitionGesDelegate boTransitionGesShouldAndWillBegin:self
                                                                              subInfo:@{@"type": @"needsRecoverWhenTouchDown"}];
                    }
                    
                    if (nil != shouldbegin &&
                        shouldbegin.boolValue) {
                        _initialDirectionInfo = _lastGesBrief.triggerDirectionInfo;
                        _initialDirectionInfo.location = _touchInfoAr.lastObject.CGRectValue.origin;
                        _triggerDirectionInfo = _initialDirectionInfo;
                        //                        [_touchInfoAr insertObject:_lastGesBrief.touchBeganVal atIndex:0];
                        
                        _needsRecoverWhenTouchDown = NO;
                        
                        [self beganTransitionGesState];
                        
                    } else {
                        _needsRecoverWhenTouchDown = NO;
                    }
                }
            }
                break;
            case UIGestureRecognizerStateChanged: {
                if (!hastranbegan) {
                    [self tryBeginTransitionGesAndMakeInfo];
                } else {
                    self.transitionGesState = UIGestureRecognizerStateChanged;
                }
            }
                break;
            case UIGestureRecognizerStateEnded:
            case UIGestureRecognizerStateCancelled: {
                //如果当前已经是begin，与内部相同变化，ended或者cancelled就可以，如果当前是其它状态，直接重置即可
                if (hastranbegan) {
                    self.transitionGesState = originState;
                    _transitionGesState = UIGestureRecognizerStatePossible;
                } else {
                    _transitionGesState = UIGestureRecognizerStateFailed;
                }
            }
                break;
            default:
                break;
        }
    }
}

- (void)saveCurrGesContextAndSetNeedsRecoverWhenTouchDown {
    if (self.touchInfoAr.count <= 0) {
        return;
    }
    NSValue *firstptval = self.touchInfoAr.firstObject;
    BOTransitionGesSliceInfo briefslice = self.triggerDirectionInfo;
    briefslice.location = firstptval.CGRectValue.origin;
    
    BOTransitionPanGestureBrief brief = (BOTransitionPanGestureBrief){
        self.touchInfoAr.copy,
        briefslice
    };
    
    _lastGesBrief = brief;
    _needsRecoverWhenTouchDown = YES;
}

- (void)clearSaveContext {
    _needsRecoverWhenTouchDown = NO;
}

- (NSNumber *)tryBeginTransitionGesAndMakeInfo {
    BOTransitionGesSliceInfo drinfo = [self generateSliceInfo];
    if (0 == drinfo.mainDirection) {
        //没有方向，什么也不做
        return nil;
    }
    
    BOOL isInitial = (2 == _touchInfoAr.count);
    if (isInitial) {
        _initialDirectionInfo = drinfo;
        _delayTrigger = NO;
    } else {
        _delayTrigger = YES;
    }
    
    _triggerDirectionInfo = drinfo;
    
    NSNumber *shouldbegin = nil;
    NSInteger responsesv = [self currPanSVAcceptDirection:drinfo.mainDirection];
    if (2 == responsesv) {
        //other sv可以响应，记录历史响应方向，并且不begin
        [self addRecordOtherSVRespondedDirection:drinfo.mainDirection];
        if ([self currPanSVAcceptDirection:drinfo.subDirection] > 0) {
            [self addRecordOtherSVRespondedDirection:drinfo.subDirection];
        }
    }
    
    if (self.transitionGesDelegate &&
        [self.transitionGesDelegate respondsToSelector:@selector(boTransitionGesShouldAndWillBegin:subInfo:)]) {
        shouldbegin = [self.transitionGesDelegate boTransitionGesShouldAndWillBegin:self subInfo:@{
            @"otherSVResponse": @(responsesv)
        }];
    }
    
    if (shouldbegin) {
        if (shouldbegin.boolValue) {
            [self correctAndSaveCurSVOffsetSugDirection:drinfo.mainDirection];
            [self beganTransitionGesState];
        } else {
            [self makeGestureStateCanceledOrFailed];
        }
    } else {
        //本次没有开始转场，如果scrollView进行了bounces响应，也记录为已响应方向
        if (1 == responsesv) {
            [self addRecordOtherSVRespondedDirection:drinfo.mainDirection];
        }
        
        if ([self currPanSVAcceptDirection:drinfo.subDirection] > 0) {
            [self addRecordOtherSVRespondedDirection:drinfo.subDirection];
        }
    }
    
    return shouldbegin;
}

/*
 return:  YES,执行完后，自己还活着
 NO： 执行完后，自己被杀死了
 */
- (BOOL)execeSimultaneouslyStrategy:(UIGestureRecognizer *)ges makeGesFailedOrCancelled:(BOOL *)makeGesFailedOrCancelled {
    if (UIGestureRecognizerStateFailed == ges.state
        || UIGestureRecognizerStateCancelled == ges.state) {
        return NO;
    }
    
    NSInteger strategy = 0;
    BOOL istran = [BOTransitionPanGesture isTransitonGes:ges];
    if (istran) {
        strategy = [self.transitionGesDelegate checkTransitionGes:self
                                               otherTransitionGes:ges
                                                         makeFail:NO];
    } else {
        strategy = [self.transitionGesDelegate boTransitionGRStrategyForGes:self
                                                                   otherGes:ges];
    }
    
    BOOL sfalive = YES;
    BOOL killges = NO;
    
    switch (strategy) {
        case 1: {
            killges = [BOTransitionPanGesture tryMakeGesFail:ges
                                                       byGes:self
                                                       force:istran];
        }
            break;
        case 2: {
            self.state = UIGestureRecognizerStateFailed;
            sfalive = NO;
        }
            break;
        default:
            break;
    }
    
    if (makeGesFailedOrCancelled) {
        *makeGesFailedOrCancelled = killges;
    }
    
    return sfalive;
}

- (void)beganTransitionGesState {
    __block BOOL hasFailed = NO;
    if (self.transitionGesDelegate &&
        [self.transitionGesDelegate respondsToSelector:@selector(boTransitionGRStrategyForGes:otherGes:)]) {
        [_otherGesWillExecSimultaneouslyStrategy enumerateObjectsUsingBlock:^(UIGestureRecognizer * _Nonnull obj,
                                                                              NSUInteger idx,
                                                                              BOOL * _Nonnull stop) {
            if (![self execeSimultaneouslyStrategy:obj makeGesFailedOrCancelled:nil]) {
                hasFailed = YES;
            }
        }];
    }
    
    if (!hasFailed) {
        __block BOOL hasDrag = NO;
        [_currPanScrollVAr enumerateObjectsUsingBlock:^(UIScrollView * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if (obj.isDragging || obj.isTracking) {
                hasDrag = YES;
                switch (obj.panGestureRecognizer.state) {
                    case UIGestureRecognizerStatePossible:
                    case UIGestureRecognizerStateBegan:
                    case UIGestureRecognizerStateChanged:
                        if (![_otherGesWillExecSimultaneouslyStrategy containsObject:obj.panGestureRecognizer]) {
                            BOOL isfc = NO;
                            [self execeSimultaneouslyStrategy:obj.panGestureRecognizer makeGesFailedOrCancelled:&isfc];
                            if (isfc) {
                                hasDrag = NO;
                            }
                        }
                        break;
                    default:
                        break;
                }
            }
        }];
        
        if (!hasDrag
            && ([self careOtherArForKey:@"cell"].count > 0
                || [self careOtherArForKey:@"control"].count > 0)) {
            /*
             有control时暂时借用系统的能力时uicontrol停止响应失效
             */
            self.state = UIGestureRecognizerStateBegan;
        }
        self.transitionGesState = UIGestureRecognizerStateBegan;
    }
    
    [_otherGesWillExecSimultaneouslyStrategy removeAllObjects];
}

- (void)setTransitionGesState:(UIGestureRecognizerState)transitionGesState {
    if (_transitionGesState != transitionGesState
        || UIGestureRecognizerStateChanged == transitionGesState
        ) {
        _transitionGesState = transitionGesState;
        
        if (self.transitionGesDelegate &&
            [self.transitionGesDelegate respondsToSelector:@selector(boTransitionGesStateDidChange:)]) {
            [self.transitionGesDelegate boTransitionGesStateDidChange:self];
        }
    }
}

#pragma mark - UIGestureRecognizerDelegate

- (void)addGesWillExecSimultaneouslyStrategy:(UIGestureRecognizer *)ges {
    if (self == ges) {
        return;
    }
    if (!_otherGesWillExecSimultaneouslyStrategy) {
        _otherGesWillExecSimultaneouslyStrategy = [NSMutableArray new];
    }
    if (![_otherGesWillExecSimultaneouslyStrategy containsObject:ges]) {
        [_otherGesWillExecSimultaneouslyStrategy addObject:ges];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if (gestureRecognizer == self
        && otherGestureRecognizer != gestureRecognizer) {
        BOOL shouldfailsf = NO;
        
        if ([BOTransitionPanGesture isTransitonGes:otherGestureRecognizer]) {
            if (self.transitionGesDelegate
                && [self.transitionGesDelegate respondsToSelector:@selector(checkTransitionGes:otherTransitionGes:makeFail:)]) {
                NSInteger checkst = [self.transitionGesDelegate checkTransitionGes:self
                                                                otherTransitionGes:otherGestureRecognizer
                                                                          makeFail:YES];
                
                if (2 == checkst) {
                    shouldfailsf = YES;
                }
            }
        }
        
        if (UIGestureRecognizerStateBegan == _transitionGesState || UIGestureRecognizerStateChanged == _transitionGesState) {
            [self execeSimultaneouslyStrategy:otherGestureRecognizer makeGesFailedOrCancelled:nil];
        } else {
            [self addGesWillExecSimultaneouslyStrategy:gestureRecognizer];
        }
        return shouldfailsf;
    } else {
        return NO;
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    
    if (gestureRecognizer == self
        && otherGestureRecognizer != gestureRecognizer) {
        BOOL shouldfailog = NO;
        if ([BOTransitionPanGesture isTransitonGes:otherGestureRecognizer]) {
            if (self.transitionGesDelegate
                && [self.transitionGesDelegate respondsToSelector:@selector(checkTransitionGes:otherTransitionGes:makeFail:)]) {
                NSInteger checkst = [self.transitionGesDelegate checkTransitionGes:self
                                                                otherTransitionGes:otherGestureRecognizer
                                                                          makeFail:YES];
                
                if (1 == checkst) {
                    shouldfailog = YES;
                }
            }
        }
        
        if (UIGestureRecognizerStateBegan == _transitionGesState || UIGestureRecognizerStateChanged == _transitionGesState) {
            [self execeSimultaneouslyStrategy:otherGestureRecognizer makeGesFailedOrCancelled:nil];
        } else {
            [self addGesWillExecSimultaneouslyStrategy:gestureRecognizer];
        }
        
        return shouldfailog;
    }
    
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if (gestureRecognizer != self
        || otherGestureRecognizer == gestureRecognizer) {
        return NO;
    }
    
    BOOL shouldsim = YES;
    if ([BOTransitionPanGesture isTransitonGes:otherGestureRecognizer]) {
        shouldsim = NO;
    }
    
    if (UIGestureRecognizerStateBegan == _transitionGesState || UIGestureRecognizerStateChanged == _transitionGesState) {
        [self execeSimultaneouslyStrategy:otherGestureRecognizer makeGesFailedOrCancelled:nil];
    } else {
        [self addGesWillExecSimultaneouslyStrategy:gestureRecognizer];
    }
    
    return shouldsim;
}

#pragma mark - 生成外部手势状态
- (NSMutableDictionary<NSString *,NSMutableArray *> *)careOtherDic {
    if (!_careOtherDic) {
        _careOtherDic = [NSMutableDictionary new];
    }
    return _careOtherDic;;
}

- (void)addCareOtherObj:(NSObject *)obj forKey:(NSString *)key {
    if (!obj
        || !key) {
        return;
    }
    
    NSMutableArray *muar = [self.careOtherDic objectForKey:key];
    if (!muar) {
        muar = [NSMutableArray new];
        [self.careOtherDic setObject:muar forKey:key];
    }
    
    [muar addObject:obj];
}

- (NSArray *)careOtherArForKey:(NSString *)key {
    if (!key) {
        return nil;
    }
    return [self.careOtherDic objectForKey:key];
}

- (void)correctAndSaveCurSVOffsetSugDirection:(UISwipeGestureRecognizerDirection)direction {
    if (_currPanScrollVAr.count > 0) {
        if (!_currPanScrollVSavOffsetAr) {
            _currPanScrollVSavOffsetAr = [NSMutableArray new];
        }
        [_currPanScrollVSavOffsetAr removeAllObjects];
        [_currPanScrollVAr enumerateObjectsUsingBlock:^(UIScrollView * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            UIEdgeInsets insets = sf_common_contentInset(obj);
            CGSize contentsz = obj.contentSize;
            CGPoint offset = obj.contentOffset;
            CGSize boundsz = obj.bounds.size;
            CGPoint shouldos = offset;
            switch (direction) {
                case UISwipeGestureRecognizerDirectionUp: {
                    CGFloat maxy = MAX(-insets.top, (contentsz.height + insets.bottom - boundsz.height));
                    if (shouldos.y > maxy) {
                        shouldos.y = maxy;
                    }
                }
                    break;
                case UISwipeGestureRecognizerDirectionDown: {
                    CGFloat miny = -insets.top;
                    if (shouldos.y < miny) {
                        shouldos.y = miny;
                    }
                }
                    break;
                case UISwipeGestureRecognizerDirectionLeft: {
                    CGFloat maxx = MAX(-insets.left, (contentsz.width + insets.right - boundsz.width));
                    if (shouldos.x > maxx) {
                        shouldos.x = maxx;
                    }
                }
                    break;
                case UISwipeGestureRecognizerDirectionRight: {
                    CGFloat minx = -insets.left;
                    if (shouldos.x < minx) {
                        shouldos.x = minx;
                    }
                }
                    break;
                default:
                    break;
            }
            
            if (!CGPointEqualToPoint(offset, shouldos)) {
                [obj setContentOffset:shouldos];
            }
            
            [_currPanScrollVSavOffsetAr addObject:[NSValue valueWithCGPoint:obj.contentOffset]];
        }];
    } else {
        [_currPanScrollVSavOffsetAr removeAllObjects];
    }
}

- (void)recoverCurSVOffset {
    if (_currPanScrollVAr.count > 0 &&
        _currPanScrollVAr.count == _currPanScrollVSavOffsetAr.count) {
        [_currPanScrollVAr enumerateObjectsUsingBlock:^(UIScrollView * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            [obj setContentOffset:_currPanScrollVSavOffsetAr[idx].CGPointValue];
        }];
    }
}

- (void)addCurrPanSV:(UIScrollView *)sv {
    if (!_currPanScrollVAr) {
        _currPanScrollVAr = [NSMutableArray new];
    }
    
    if (![_currPanScrollVAr containsObject:sv]) {
        [sv.panGestureRecognizer addTarget:self action:@selector(boTransitionOtherSVOnPan:)];
        [_currPanScrollVAr addObject:sv];
    }
}

- (void)clearCurrSVRecord {
    [_currPanScrollVAr enumerateObjectsUsingBlock:^(UIScrollView * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [obj.panGestureRecognizer removeTarget:self action:@selector(boTransitionOtherSVOnPan:)];
    }];
    [_currPanScrollVAr removeAllObjects];
    _currPanScrollVAr = nil;
    [_currPanScrollVSavOffsetAr removeAllObjects];
    _currPanScrollVSavOffsetAr = nil;
    [_otherSVRespondedDirectionRecord removeAllObjects];
    _otherSVRespondedDirectionRecord = nil;
    
    _delayTrigger = NO;
}

- (void)addRecordOtherSVRespondedDirection:(UISwipeGestureRecognizerDirection)direction {
    if (!_otherSVRespondedDirectionRecord) {
        _otherSVRespondedDirectionRecord = [[NSMutableSet alloc] init];
    }
    
    [_otherSVRespondedDirectionRecord addObject:@(direction)];
}

- (void)makeGestureStateCanceledOrFailed {
    
    self.state = UIGestureRecognizerStateFailed;
    
    switch (self.transitionGesState) {
        case UIGestureRecognizerStatePossible:
            _transitionGesState = UIGestureRecognizerStateFailed;
            break;
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            self.transitionGesState = UIGestureRecognizerStateCancelled;
            break;
        default:
            break;
    }
}

/*
 其它scrollView的触发，
 */
- (void)boTransitionOtherSVOnPan:(UIPanGestureRecognizer *)panGes {
    
    BOOL hastranbegan = (UIGestureRecognizerStateBegan == _transitionGesState
                         || UIGestureRecognizerStateChanged == _transitionGesState);
    
    switch (panGes.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged: {
            if (!hastranbegan) {
                [self tryBeginTransitionGesAndMakeInfo];
            } else {
                [self recoverCurSVOffset];
            }
        }
            break;
        default: {
        }
            break;
    }
    
}

#pragma mark - helper func

- (BOTransitionGesSliceInfo)generateSliceInfo {
    
    CGPoint velocity = [self velocityInCurrView];
    
    UISwipeGestureRecognizerDirection vdi = 0;
    if (velocity.y > 0) {
        vdi = UISwipeGestureRecognizerDirectionDown;
    } else if (velocity.y < 0) {
        vdi = UISwipeGestureRecognizerDirectionUp;
    }
    
    UISwipeGestureRecognizerDirection hdi = 0;
    if (velocity.x > 0) {
        hdi = UISwipeGestureRecognizerDirectionRight;
    } else if (velocity.x < 0) {
        hdi = UISwipeGestureRecognizerDirectionLeft;
    }
    
    UISwipeGestureRecognizerDirection maindi = 0;
    UISwipeGestureRecognizerDirection subdi = 0;
    BOOL v = (fabs(velocity.y) > fabs(velocity.x));
    if (v) {
        maindi = vdi;
        subdi = hdi;
    } else {
        maindi = hdi;
        subdi = vdi;
    }
    
    CGPoint loc = [self locationInView:self.view];
    return (BOTransitionGesSliceInfo){maindi, subdi, velocity, loc};
}

/*
 一次只支持传一个方向
 0 不能滑动 不能bounces
 1 for  bounces
 2 normal scroll
 */
- (NSInteger)currPanSVAcceptDirection:(UISwipeGestureRecognizerDirection)gesDirection {
    if (_currPanScrollVAr.count <= 0) {
        return 0;
    }
    
    CGFloat onepixel = (1.f / [UIScreen mainScreen].scale);
    
    __block BOOL hasscroll = NO;
    __block BOOL hasbounces = NO;
    [_currPanScrollVAr enumerateObjectsUsingBlock:^(UIScrollView * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        switch (obj.panGestureRecognizer.state) {
            case UIGestureRecognizerStateCancelled:
            case UIGestureRecognizerStateEnded:
            case UIGestureRecognizerStateFailed:
                return;
            default:
                break;
        }
        UIEdgeInsets insets = sf_common_contentInset(obj);
        CGSize contentsz = obj.contentSize;
        CGPoint offset = obj.contentOffset;
        CGSize boundsz = obj.bounds.size;
        switch (gesDirection) {
            case UISwipeGestureRecognizerDirectionUp:
                if ((contentsz.height + insets.bottom)
                    >
                    (offset.y + boundsz.height + onepixel)) {
                    hasscroll = YES;
                    *stop = YES;
                } else if (obj.bounces) {
                    if (obj.alwaysBounceVertical) {
                        hasbounces = YES;
                    } else {
                        if (contentsz.height + insets.top + insets.bottom > boundsz.height) {
                            hasbounces = YES;
                        }
                    }
                }
                break;
            case UISwipeGestureRecognizerDirectionDown:
                if (offset.y
                    >
                    (-insets.top + onepixel)) {
                    hasscroll = YES;
                    *stop = YES;
                } else if (obj.bounces) {
                    if (obj.alwaysBounceVertical) {
                        hasbounces = YES;
                    } else {
                        if (contentsz.height + insets.top + insets.bottom > boundsz.height) {
                            hasbounces = YES;
                        }
                    }
                }
                break;
            case UISwipeGestureRecognizerDirectionLeft:
                if ((contentsz.width + insets.right)
                    >
                    (offset.x + boundsz.width + onepixel)) {
                    hasscroll = YES;
                    *stop = YES;
                } else if (obj.bounces) {
                    if (obj.alwaysBounceHorizontal) {
                        hasbounces = YES;
                    } else {
                        if (contentsz.width + insets.left + insets.right > boundsz.width) {
                            hasbounces = YES;
                        }
                    }
                }
                break;
            case UISwipeGestureRecognizerDirectionRight:
                if (offset.x
                    >
                    (-insets.left + onepixel)) {
                    hasscroll = YES;
                    *stop = YES;
                } else if (obj.bounces) {
                    if (obj.alwaysBounceHorizontal) {
                        hasbounces = YES;
                    } else {
                        if (contentsz.width + insets.left + insets.right > boundsz.width) {
                            hasbounces = YES;
                        }
                    }
                }
                break;
            default:
                break;
        }
    }];
    if (hasscroll) {
        return 2;
    } else if (hasbounces) {
        return 1;
    } else {
        return 0;
    }
}

- (BOOL)currPanSVInBounces {
    if (_currPanScrollVAr.count <= 0) {
        return NO;
    }
    
    CGFloat onepixel = (1.f / [UIScreen mainScreen].scale);
    
    __block BOOL hasbounces = NO;
    [_currPanScrollVAr enumerateObjectsUsingBlock:^(UIScrollView * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        UIEdgeInsets insets = sf_common_contentInset(obj);
        CGSize contentsz = obj.contentSize;
        CGPoint offset = obj.contentOffset;
        CGSize boundsz = obj.bounds.size;
        if (obj.bounces) {
            if (((contentsz.height + insets.top + insets.bottom) > boundsz.height)
                &&
                ((offset.y + boundsz.height)
                 >
                 (contentsz.height + insets.bottom + onepixel))) {
                hasbounces = YES;
            } else if (offset.y
                       <
                       (-insets.top - onepixel)) {
                hasbounces = YES;
            } else if (((contentsz.width + insets.left + insets.right) > boundsz.width)
                       &&
                       ((offset.x + boundsz.width) >
                        (contentsz.width + insets.right + onepixel))) {
                hasbounces = YES;
            } else if (offset.x
                       <
                       (-insets.left - onepixel)) {
                hasbounces = YES;
            }
            
            if (hasbounces) {
                *stop = YES;
            }
        }
        
    }];
    
    return hasbounces;
}

- (void)insertBeganPt:(CGPoint)beganPt {
    [_touchInfoAr insertObject:@((CGRect){beganPt, CGSizeZero}) atIndex:0];
}

+ (BOOL)tryMakeGesFail:(UIGestureRecognizer *)gesShouldFail
                 byGes:(UIGestureRecognizer *)ges
                 force:(BOOL)force {
    BOOL shouldSimultaneously = NO;
    if (!force) {
        if (gesShouldFail.delegate &&
            [gesShouldFail.delegate respondsToSelector:@selector(gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:)]) {
            shouldSimultaneously = [gesShouldFail.delegate gestureRecognizer:gesShouldFail
                shouldRecognizeSimultaneouslyWithGestureRecognizer:ges];
        }
    }
    
    if (force
        || (!shouldSimultaneously
            && [gesShouldFail canBePreventedByGestureRecognizer:ges])) {
        switch (gesShouldFail.state) {
            case UIGestureRecognizerStatePossible:
                gesShouldFail.state = UIGestureRecognizerStateFailed;
                break;
            case UIGestureRecognizerStateBegan:
            case UIGestureRecognizerStateChanged:
                gesShouldFail.state = UIGestureRecognizerStateCancelled;
                break;
            default:
                break;
        }
        
        return YES;
    }
    
    return NO;
}

+ (NSInteger)isTransitonGes:(UIGestureRecognizer *)ges {
    UIResponder *vnres = ges.view.nextResponder;
    if ([vnres isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nc = (UINavigationController *)vnres;
        if (nc.interactivePopGestureRecognizer == ges) {
            return 1;
        } else if ([ges isKindOfClass:[BOTransitionPanGesture class]]) {
            return 2;
        }
    }
    
    return 0;
}

@end
