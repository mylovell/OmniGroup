// Copyright 2010-2014 Omni Development, Inc. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import <OmniUIDocument/OUIDocumentPickerScrollView.h>

#import <OmniDocumentStore/ODSFileItem.h>
#import <OmniDocumentStore/ODSFolderItem.h>
#import <OmniFoundation/NSArray-OFExtensions.h>
#import <OmniFoundation/OFCFCallbacks.h>
#import <OmniFoundation/OFExtent.h>
#import <OmniUI/OUIAppController.h>
#import <OmniUI/OUIDirectTapGestureRecognizer.h>
#import <OmniUI/OUIDragGestureRecognizer.h>
#import <OmniUI/UIGestureRecognizer-OUIExtensions.h>
#import <OmniUI/UIView-OUIExtensions.h>
#import <OmniUIDocument/OUIDocumentAppController.h>
#import <OmniUIDocument/OUIDocumentPickerFileItemView.h>
#import <OmniUIDocument/OUIDocumentPickerGroupItemView.h>
#import <OmniUIDocument/OUIDocumentPreview.h>
#import <OmniUIDocument/OUIDocumentPreviewView.h>
#import <OmniUIDocument/OUIDocumentPickerItemMetadataView.h>
#import <OmniUIDocument/OUIDocumentPickerViewController.h>

#import "OUIDocumentPickerItemView-Internal.h"
#import "OUIDocumentRenameSession.h"

RCS_ID("$Id$");

NSString * const OUIDocumentPickerScrollViewItemsBinding = @"items";

#if 0 && defined(DEBUG_bungi)
    #define DEBUG_LAYOUT(format, ...) NSLog(@"DOC LAYOUT: " format, ## __VA_ARGS__)
#else
    #define DEBUG_LAYOUT(format, ...)
#endif

static const CGFloat kItemVerticalPadding = 27;
static const CGFloat kItemHorizontalPadding = 27;

static const CGFloat kItemNormalSize = 220.0;
static const CGFloat kItemSmallSize = 140.0;


typedef struct LayoutInfo {
    CGFloat topControlsHeight;
    CGRect contentRect;
    CGSize itemSize;
    NSUInteger itemsPerRow;
} LayoutInfo;

static LayoutInfo _updateLayout(OUIDocumentPickerScrollView *self);

// Items are laid out in a fixed size grid.
static CGRect _frameForPositionAtIndex(NSUInteger itemIndex, LayoutInfo layoutInfo)
{
    OBPRECONDITION(layoutInfo.itemSize.width > 0);
    OBPRECONDITION(layoutInfo.itemSize.height > 0);
    OBPRECONDITION(layoutInfo.itemsPerRow > 0);
    
    NSUInteger row = itemIndex / layoutInfo.itemsPerRow;
    NSUInteger column = itemIndex % layoutInfo.itemsPerRow;
    
    // If the item views plus their padding don't completely fill our layoutWidth, distribute the remaining space as margins on either sides of the scrollview.
    CGFloat sideMargin = (layoutInfo.contentRect.size.width - (kItemHorizontalPadding + layoutInfo.itemsPerRow * (layoutInfo.itemSize.width + kItemHorizontalPadding))) / 2;
    
    CGRect frame = (CGRect){
        .origin.x = kItemHorizontalPadding + column * (layoutInfo.itemSize.width + kItemHorizontalPadding) + sideMargin,
        .origin.y = layoutInfo.topControlsHeight + kItemVerticalPadding + row * (layoutInfo.itemSize.height + kItemVerticalPadding),
        .size = layoutInfo.itemSize};
    
    // CGRectIntegral can make the rect bigger when the size is integral but the position is fractional. We want the size to remain the same.
    CGRect integralFrame;
    integralFrame.origin.x = floor(frame.origin.x);
    integralFrame.origin.y = floor(frame.origin.y);
    integralFrame.size = frame.size;
    
    return CGRectIntegral(integralFrame);
}

static CGPoint _clampContentOffset(OUIDocumentPickerScrollView *self, CGPoint contentOffset)
{
    UIEdgeInsets contentInset = self.contentInset;
    OFExtent contentOffsetYExtent = OFExtentMake(-contentInset.top, MAX(0, self.contentSize.height - self.bounds.size.height + contentInset.top + self.contentInset.bottom));
    CGPoint clampedContentOffset = CGPointMake(contentOffset.x, OFExtentClampValue(contentOffsetYExtent, contentOffset.y));
    return clampedContentOffset;
}

@interface OUIDocumentPickerScrollView (/*Private*/)

@property (nonatomic, copy) NSArray *currentSortDescriptors;

- (CGSize)_gridSize;
- (void)_startDragRecognizer:(OUIDragGestureRecognizer *)recognizer;
@end

@implementation OUIDocumentPickerScrollView
{    
    NSMutableSet *_items;
    NSArray *_sortedItems;
    id _draggingDestinationItem;
    
    NSMutableSet *_itemsBeingAdded;
    NSMutableSet *_itemsBeingRemoved;
    NSMutableSet *_itemsIgnoredForLayout;
    NSDictionary *_fileItemToPreview; // For visible or nearly visible files
    
    struct {
        unsigned int isAnimatingRotationChange:1;
        unsigned int isEditing:1;
        unsigned int isAddingItems:1;
    } _flags;
    
    OUIDocumentPickerItemSort _itemSort;

    NSArray *_itemViewsForPreviousOrientation;
    NSArray *_fileItemViews;
    NSArray *_groupItemViews;
        
    OUIDragGestureRecognizer *_startDragRecognizer;
    
    NSTimeInterval _rotationDuration;
    
    NSMutableArray *_scrollFinishedCompletionHandlers;
}

static id _commonInit(OUIDocumentPickerScrollView *self)
{
    self->_items = [[NSMutableSet alloc] init];
    self->_itemsBeingAdded = [[NSMutableSet alloc] init];
    self->_itemsBeingRemoved = [[NSMutableSet alloc] init];
    self->_itemsIgnoredForLayout = [[NSMutableSet alloc] init];
    
    self.showsVerticalScrollIndicator = YES;
    self.showsHorizontalScrollIndicator = NO;
    self.alwaysBounceVertical = YES;
    return self;
}

- initWithFrame:(CGRect)frame;
{
    if (!(self = [super initWithFrame:frame]))
        return nil;
    return _commonInit(self);
}

- initWithCoder:(NSCoder *)coder;
{
    if (!(self = [super initWithCoder:coder]))
        return nil;
    return _commonInit(self);
}

- (void)dealloc;
{    
    [_fileItemToPreview enumerateKeysAndObjectsUsingBlock:^(ODSStore *fileItem, OUIDocumentPreview *preview, BOOL *stop) {
        [preview decrementDisplayCount];
    }];
    
    for (ODSItem *item in _items) {
        [self _endObservingSortKeysForItem:item];
    }
    
    _startDragRecognizer.delegate = nil;
    _startDragRecognizer = nil;
}

- (id <OUIDocumentPickerScrollViewDelegate>)delegate;
{
    return (id <OUIDocumentPickerScrollViewDelegate>)[super delegate];
}

- (void)setDelegate:(id <OUIDocumentPickerScrollViewDelegate>)delegate;
{
    OBPRECONDITION(!delegate || [delegate conformsToProtocol:@protocol(OUIDocumentPickerScrollViewDelegate)]);

    [super setDelegate:delegate];
    
    // If the delegate changes, the sort descriptors can change also.
    [self _updateSortDescriptors];
}

static NSUInteger _itemViewsForGridSize(CGSize gridSize)
{
    OBPRECONDITION(gridSize.width == rint(gridSize.width));
    
    NSUInteger width = ceil(gridSize.width);
    NSUInteger height = ceil(gridSize.height + 1.0); // partial row scrolled off the top, partial row off the bottom
    
    return width * height;
}

static NSArray *_newItemViews(OUIDocumentPickerScrollView *self, Class itemViewClass, BOOL isReadOnly)
{
    OBASSERT(OBClassIsSubclassOfClass(itemViewClass, [OUIDocumentPickerItemView class]));
    OBASSERT(itemViewClass != [OUIDocumentPickerItemView class]);
    
    NSMutableArray *itemViews = [[NSMutableArray alloc] init];

    NSUInteger neededItemViewCount = _itemViewsForGridSize([self _gridSize]);
    while (neededItemViewCount--) {

        OUIDocumentPickerItemView *itemView = [[itemViewClass alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
        itemView.isReadOnly = isReadOnly;
        
        [itemViews addObject:itemView];

        [itemView addTarget:self action:@selector(_itemViewTapped:) forControlEvents:UIControlEventTouchUpInside];
        
        itemView.hidden = YES;
        [self addSubview:itemView];
    }
    
    NSArray *result = [itemViews copy];
    return result;
}

- (void)retileItems;
{
    if (_flags.isAnimatingRotationChange) {
        OBASSERT(self.window);
        // We are on screen and rotating, so -willRotate should have been called. Still, we'll try to handle this reasonably below.
        OBASSERT(_fileItemViews == nil);
        OBASSERT(_groupItemViews == nil);
    } else {
        // The device was rotated while our view controller was off screen. It doesn't get told about the rotation in that case and we just get a landscape change. We might also have been covered by a modal view controller but are being revealed again.
        OBASSERT(self.window == nil);
    }
    
    // Figure out whether we should do the animation outside of the OUIWithoutAnimating block (else +areAnimationsEnabled will be trivially NO).
    BOOL shouldCrossFade = _flags.isAnimatingRotationChange && [UIView areAnimationsEnabled];

    BOOL isReadOnly = [self.delegate isReadyOnlyForDocumentPickerScrollView:self];
    // Make the new views (which will start out hidden).
    OUIWithoutAnimating(^{
        Class fileItemViewClass = [OUIDocumentPickerFileItemView class];
        [_fileItemViews makeObjectsPerformSelector:@selector(removeFromSuperview)];
        _fileItemViews = _newItemViews(self, fileItemViewClass, isReadOnly);
        
        [_groupItemViews makeObjectsPerformSelector:@selector(removeFromSuperview)];
        _groupItemViews = _newItemViews(self, [OUIDocumentPickerGroupItemView class], isReadOnly);
        
        if (shouldCrossFade) {
            for (OUIDocumentPickerItemView *itemView in _fileItemViews) {
                itemView.alpha = 0;
            }
            for (OUIDocumentPickerItemView *itemView in _groupItemViews) {
                itemView.alpha = 0;
            }
        }
    });
    
    // Now fade in the views (at least the ones that have their hidden flag cleared on the next layout).
    if (shouldCrossFade) {
        [UIView beginAnimations:nil context:NULL];
        {
            if (_rotationDuration > 0)
                [UIView setAnimationDuration:_rotationDuration];
            for (OUIDocumentPickerItemView *itemView in _fileItemViews) {
                itemView.alpha = 1;
            }
            for (OUIDocumentPickerItemView *itemView in _groupItemViews) {
                itemView.alpha = 1;
            }
        }
        [UIView commitAnimations];
    }
    
    _shouldHideTopControlsOnNextLayout = YES;
    
    [self setNeedsLayout];
}

@synthesize items = _items;

- (void)startAddingItems:(NSSet *)toAdd;
{
    OBPRECONDITION([toAdd intersectsSet:_items] == NO);
    OBPRECONDITION([toAdd intersectsSet:_itemsBeingAdded] == NO);

    [_items unionSet:toAdd];
    [_itemsBeingAdded unionSet:toAdd];
}

- (void)finishAddingItems:(NSSet *)toAdd;
{
    OBPRECONDITION([toAdd isSubsetOfSet:_items]);
    OBPRECONDITION([toAdd isSubsetOfSet:_itemsBeingAdded]);

    [_itemsBeingAdded minusSet:toAdd];
    
    for (ODSItem *item in toAdd) {
        [self _beginObservingSortKeysForItem:item];
        
        OUIDocumentPickerItemView *itemView = [self itemViewForItem:item];
        OBASSERT(!itemView || itemView.shrunken);
        itemView.shrunken = NO;
    }
    
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
}

@synthesize itemsBeingAdded = _itemsBeingAdded;

- (void)startRemovingItems:(NSSet *)toRemove;
{
    OBPRECONDITION([toRemove isSubsetOfSet:_items]);
    OBPRECONDITION([toRemove intersectsSet:_itemsBeingRemoved] == NO);

    [_itemsBeingRemoved unionSet:toRemove];

    for (ODSItem *item in toRemove) {
        [self _endObservingSortKeysForItem:item];
        
        OUIDocumentPickerItemView *itemView = [self itemViewForItem:item];
        itemView.shrunken = YES;
    }
}

- (void)finishRemovingItems:(NSSet *)toRemove;
{
    OBPRECONDITION([toRemove isSubsetOfSet:_items]);
    OBPRECONDITION([toRemove isSubsetOfSet:_itemsBeingRemoved]);

    for (ODSItem *item in toRemove) {
        OUIDocumentPickerItemView *itemView = [self itemViewForItem:item];
        OBASSERT(!itemView || itemView.shrunken);
        itemView.shrunken = NO;
    }

    [_itemsBeingRemoved minusSet:toRemove];
    [_items minusSet:toRemove];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
}

@synthesize itemsBeingRemoved = _itemsBeingRemoved;

static void * ItemSortKeyContext = &ItemSortKeyContext;
- (void)_beginObservingSortKeysForItem:(ODSItem *)item;
{
    for (NSSortDescriptor *sortDescriptor in self.currentSortDescriptors) {
        // Since not all sort descriptors are key-based (like block sort descriptors) we ignore the sort descriptor if it doesn't have a key. This isn't perfect, but it'll work for now.
        NSString *key = sortDescriptor.key;
        if (key) {
            [item addObserver:self forKeyPath:key options:NSKeyValueObservingOptionNew context:ItemSortKeyContext];
        }
    }
}

- (void)_endObservingSortKeysForItem:(ODSItem *)item;
{
    for (NSSortDescriptor *sortDescriptor in self.currentSortDescriptors) {
        NSString *key = sortDescriptor.key;
        if (key) {
            [item removeObserver:self forKeyPath:key context:ItemSortKeyContext];
        }
    }
}

- (void)_updateSortDescriptors;
{
    NSArray *newSortDescriptors = nil;
    if ([[self delegate] respondsToSelector:@selector(sortDescriptorsForDocumentPickerScrollView:)]) {
        newSortDescriptors = [[self delegate] sortDescriptorsForDocumentPickerScrollView:self];
    }
    else {
        newSortDescriptors = [OUIDocumentPickerViewController sortDescriptors];
    }

    // Only refresh if the sort descriptors have actually changed.
    if (OFNOTEQUAL(newSortDescriptors, self.currentSortDescriptors)) {
        for (ODSItem *item in _items) {
            [self _endObservingSortKeysForItem:item];
        }
        
        self.currentSortDescriptors = newSortDescriptors;
        
        for (ODSItem *item in _items) {
            [self _beginObservingSortKeysForItem:item];
        }
    }
}

- (void)_sortItems:(BOOL)updateDescriptors;
{
    OBASSERT(_items);
    if (!_items) {
        return;
    }

    if (updateDescriptors) {
        [self _updateSortDescriptors];
    }
    
    NSArray *newSort = [[_items allObjects] sortedArrayUsingDescriptors:self.currentSortDescriptors];
    if (OFNOTEQUAL(newSort, _sortedItems)) {
        _sortedItems = [newSort copy];
        [self setNeedsLayout];
    }
}

- (void)sortItems;
{
    // This API was designed to ask it's delegate for the sort descriptors when -sortItems is called. We may want to move away from that design, but for now we need to leave it because external callers of this API might expect this.
    [self _sortItems:YES];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated;
{
    _flags.isEditing = editing;
    
    for (OUIDocumentPickerItemView *itemView in _fileItemViews)
        [itemView setEditing:editing animated:animated];
    for (OUIDocumentPickerItemView *itemView in _groupItemViews)
        [itemView setEditing:editing animated:animated];
}

- (void)setItemSort:(OUIDocumentPickerItemSort)_sort;
{
    _itemSort = _sort;
    [self _sortItems:YES];

    if (self.window != nil) {
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0 options:0 animations:^{
            [self layoutIfNeeded];
        } completion:^(BOOL finished){
        }];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context;
{
    if (context == ItemSortKeyContext) {
        OBASSERT([_items containsObject:object]);
        OBASSERT([_currentSortDescriptors first:^BOOL(NSSortDescriptor *desc){ return [desc.key isEqual:keyPath]; }]);
        
        [self _sortItems:NO];
    }
    else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@synthesize sortedItems = _sortedItems;
@synthesize itemSort = _itemSort;

@synthesize draggingDestinationItem = _draggingDestinationItem;
- (void)setDraggingDestinationItem:(id)draggingDestinationItem;
{
    if (_draggingDestinationItem == draggingDestinationItem)
        return;
    _draggingDestinationItem = draggingDestinationItem;
    
    [self setNeedsLayout];
}

static CGPoint _contentOffsetForCenteringItem(OUIDocumentPickerScrollView *self, CGRect itemFrame)
{
    UIEdgeInsets contentInset = self.contentInset;
    CGRect viewportRect = UIEdgeInsetsInsetRect(self.bounds, contentInset);
    return CGPointMake(-contentInset.left, floor(CGRectGetMinY(itemFrame) + CGRectGetHeight(itemFrame) - (CGRectGetHeight(viewportRect) / 2) - contentInset.top));
}

- (void)scrollItemToVisible:(ODSItem *)item animated:(BOOL)animated;
{
    [self scrollItemsToVisible:[NSArray arrayWithObjects:item, nil] animated:animated];
}

- (void)scrollItemsToVisible:(id <NSFastEnumeration>)items animated:(BOOL)animated;
{
    [self scrollItemsToVisible:items animated:animated completion:nil];
}

- (void)scrollItemsToVisible:(id <NSFastEnumeration>)items animated:(BOOL)animated completion:(void (^)(void))completion;
{
    [self layoutIfNeeded];

    CGPoint contentOffset = self.contentOffset;
    CGRect bounds = self.bounds;
    
    CGRect contentRect;
    contentRect.origin = contentOffset;
    contentRect.size = bounds.size;
    
    CGRect itemsFrame = CGRectNull;
    for (ODSItem *item in items) {
        CGRect itemFrame = [self frameForItem:item];
        if (CGRectIsNull(itemFrame))
            itemsFrame = itemFrame;
        else
            itemsFrame = CGRectUnion(itemsFrame, itemFrame);
    }

    // If all the rects are fully visible, nothing to do.
    if (CGRectContainsRect(contentRect, itemsFrame)) {
        // If we have some pending handlers, calling this one first would mean we're calling handlers out of order with when they were specified. Likely this is a bug (but we have to call it anway)
        OBASSERT(_scrollFinishedCompletionHandlers == nil);
        if (completion)
            completion();
        return;
    }
    
    if (completion) {
        if (!_scrollFinishedCompletionHandlers)
            _scrollFinishedCompletionHandlers = [NSMutableArray new];
        [_scrollFinishedCompletionHandlers addObject:[completion copy]];
    }
    
    CGPoint clampedContentOffset = _clampContentOffset(self, _contentOffsetForCenteringItem(self, itemsFrame));
    
    if (!CGPointEqualToPoint(contentOffset, clampedContentOffset)) {
        [self setContentOffset:clampedContentOffset animated:animated];
        [self setNeedsLayout];
        [self layoutIfNeeded];
    }
}

- (void)performScrollFinishedHandlers;
{
    NSArray *handlers = _scrollFinishedCompletionHandlers;
    _scrollFinishedCompletionHandlers = nil;
    
    for (void (^handler)(void) in handlers)
        handler();
}

- (CGRect)frameForItem:(ODSItem *)item;
{
    LayoutInfo layoutInfo = _updateLayout(self);
    CGSize itemSize = layoutInfo.itemSize;

    if (itemSize.width <= 0 || itemSize.height <= 0) {
        // We aren't sized right yet
        OBASSERT_NOT_REACHED("Asking for the frame of an item before we are laid out.");
        return CGRectZero;
    }

    NSUInteger positionIndex;
    if ([_itemsIgnoredForLayout count] > 0) {
        positionIndex = NSNotFound;
        
        NSUInteger itemIndex = 0;
        for (ODSItem *sortedItem in _sortedItems) {
            if ([_itemsIgnoredForLayout member:sortedItem])
                continue;
            if (sortedItem == item) {
                positionIndex = itemIndex;
                break;
            }
            itemIndex++;
        }
    } else {
        positionIndex = [_sortedItems indexOfObjectIdenticalTo:item];
    }
    
    if (positionIndex == NSNotFound) {
        OBASSERT([_items member:item] == nil); // If we didn't find the positionIndex it should mean that the item isn't in _items or _sortedItems. If the item is in _items but not _sortedItems, its probably becase we havn't yet called -sortItems.
        OBASSERT_NOT_REACHED("Asking for the frame of an item that is unknown/ignored");
        return CGRectZero;
    }

    return _frameForPositionAtIndex(positionIndex, layoutInfo);
}

- (OUIDocumentPickerItemView *)itemViewForItem:(ODSItem *)item;
{
    for (OUIDocumentPickerFileItemView *itemView in _fileItemViews) {
        if (itemView.item == item)
            return itemView;
    }

    for (OUIDocumentPickerGroupItemView *itemView in _groupItemViews) {
        if (itemView.item == item)
            return itemView;
    }
    
    return nil;
}

- (OUIDocumentPickerFileItemView *)fileItemViewForFileItem:(ODSFileItem *)fileItem;
{
    for (OUIDocumentPickerFileItemView *fileItemView in _fileItemViews) {
        if (fileItemView.item == fileItem)
            return fileItemView;
    }
    
    return nil;
}

// We don't use -[UIGestureRecognizer(OUIExtensions) hitView] or our own -hitTest: since while we are in the middle of dragging, extra item views will be added to us by the drag session.
static OUIDocumentPickerItemView *_itemViewHitByRecognizer(NSArray *itemViews, UIGestureRecognizer *recognizer)
{
    for (OUIDocumentPickerItemView *itemView in itemViews) {
        // The -hitTest:withEvent: below doesn't consider ancestor isHidden flags.
        if (itemView.hidden)
            continue;
        UIView *hitView = [itemView hitTest:[recognizer locationInView:itemView] withEvent:nil];
        if (hitView)
            return itemView;
    }
    return nil;
}

- (OUIDocumentPickerItemView *)itemViewHitByRecognizer:(UIGestureRecognizer *)recognizer;
{
    OUIDocumentPickerItemView *itemView = _itemViewHitByRecognizer(_fileItemViews, recognizer);
    if (itemView)
        return itemView;
    return _itemViewHitByRecognizer(_groupItemViews, recognizer);
}

// Used to pick file items that are visible for automatic download (if they are small and we are on wi-fi) or preview generation.
- (ODSFileItem *)preferredVisibleItemFromSet:(NSSet *)fileItemsNeedingPreviewUpdate;
{
    // Prefer to update items that are visible, and then among those, do items starting at the top-left.
    ODSFileItem *bestFileItem = nil;
    CGFloat bestVisiblePercentage = 0;
    CGPoint bestOrigin = CGPointZero;

    CGPoint contentOffset = self.contentOffset;
    CGRect bounds = self.bounds;
    
    CGRect contentRect;
    contentRect.origin = contentOffset;
    contentRect.size = bounds.size;

    OFExtent contentYExtent = OFExtentFromRectYRange(contentRect);
    if (contentYExtent.length <= 1)
        return nil; // Avoid divide by zero below.
    
    for (OUIDocumentPickerFileItemView *fileItemView in _fileItemViews) {
        ODSFileItem *fileItem = (ODSFileItem *)fileItemView.item;
        if ([fileItemsNeedingPreviewUpdate member:fileItem] == nil)
            continue;

        CGRect itemFrame = fileItemView.frame;
        CGPoint itemOrigin = itemFrame.origin;
        OFExtent itemYExtent = OFExtentFromRectYRange(itemFrame);

        OFExtent itemVisibleYExtent = OFExtentIntersection(itemYExtent, contentYExtent);
        CGFloat itemVisiblePercentage = itemVisibleYExtent.length / contentYExtent.length;
        
        if (itemVisiblePercentage > bestVisiblePercentage ||
            itemOrigin.y < bestOrigin.y ||
            (itemOrigin.y == bestOrigin.y && itemOrigin.x < bestOrigin.x)) {
            bestFileItem = fileItem;
            bestVisiblePercentage = itemVisiblePercentage;
            bestOrigin = itemOrigin;
        }
    }
    
    return bestFileItem;
}

- (void)previewsUpdatedForFileItem:(ODSFileItem *)fileItem;
{
    for (OUIDocumentPickerFileItemView *fileItemView in _fileItemViews) {
        if (fileItemView.item == fileItem) {
            [fileItemView previewsUpdated];
            return;
        }
    }
    
    for (OUIDocumentPickerGroupItemView *groupItemView in _groupItemViews) {
        ODSFolderItem *groupItem = (ODSFolderItem *)groupItemView.item;
        if ([groupItem.childItems member:fileItem]) {
            [groupItemView previewsUpdated];
            return;
        }
    }
}

- (void)previewedItemsChangedForGroups;
{
    [_groupItemViews makeObjectsPerformSelector:@selector(previewedItemsChanged)];
}

- (void)startIgnoringItemForLayout:(ODSItem *)item;
{
    OBASSERT(!([_itemsIgnoredForLayout containsObject:item]));
    [_itemsIgnoredForLayout addObject:item];
}

- (void)stopIgnoringItemForLayout:(ODSItem *)item;
{
    OBASSERT([_itemsIgnoredForLayout containsObject:item]);
    [_itemsIgnoredForLayout removeObject:item];
}

#pragma mark - UIView

- (void)willMoveToWindow:(UIWindow *)newWindow;
{
    [super willMoveToWindow:newWindow];
    
    if (newWindow && _startDragRecognizer == nil && ![self.delegate isReadyOnlyForDocumentPickerScrollView:self]) {
        // UIScrollView has recognizers, but doesn't delcare that it is their delegate. Hopefully they are leaving this open for subclassers.
        OBASSERT([UIScrollView conformsToProtocol:@protocol(UIGestureRecognizerDelegate)] == NO);

        _startDragRecognizer = [[OUIDragGestureRecognizer alloc] initWithTarget:self action:@selector(_startDragRecognizer:)];
        _startDragRecognizer.delegate = self;
        _startDragRecognizer.holdDuration = 0.5; // taken from UILongPressGestureRecognizer.h
        _startDragRecognizer.requiresHoldToComplete = YES;
        
        [self addGestureRecognizer:_startDragRecognizer];
    } else if (newWindow == nil && _startDragRecognizer != nil) {
        [self removeGestureRecognizer:_startDragRecognizer];
        _startDragRecognizer.delegate = nil;
        _startDragRecognizer = nil;
    }
}

static LayoutInfo _updateLayout(OUIDocumentPickerScrollView *self)
{
    OBFinishPortingLater("<bug:///105447> (Unassigned: Stop using deprecated interfaceOrientation [adaptability])");
    CGSize gridSize = [self _gridSize];
    OBASSERT(gridSize.width >= 1);
    OBASSERT(gridSize.width == trunc(gridSize.width));
    OBASSERT(gridSize.height >= 1);
    
    if (_itemViewsForGridSize(gridSize) > self->_fileItemViews.count) {
        [self retileItems];
    }
        
    NSUInteger itemsPerRow = gridSize.width;
    CGSize layoutSize = self.bounds.size;
    CGSize itemSize = CGSizeMake(kItemNormalSize, kItemNormalSize);
    
    // For devices where screen sizes are too small for our preferred items, here's a smaller size
    if (layoutSize.width / gridSize.width < (itemSize.width + kItemHorizontalPadding))
        itemSize = CGSizeMake(kItemSmallSize, kItemSmallSize);
    
    if (itemSize.width <= 0 || itemSize.height <= 0) {
        // We aren't sized right yet
        DEBUG_LAYOUT(@"  Bailing since we have zero size");
        LayoutInfo layoutInfo;
        memset(&layoutInfo, 0, sizeof(layoutInfo));
        return layoutInfo;
    }
    
    CGFloat topControlsHeight = CGRectGetHeight(self->_topControls.frame);
    CGRect contentRect;
    {
        NSUInteger itemCount = [self->_sortedItems count];
        NSUInteger rowCount = (itemCount / itemsPerRow) + ((itemCount % itemsPerRow) == 0 ? 0 : 1);
        
        CGRect bounds = self.bounds;
        CGSize contentSize = CGSizeMake(layoutSize.width, rowCount * (itemSize.height + kItemVerticalPadding) + topControlsHeight + kItemVerticalPadding);
        contentSize.height = MAX(contentSize.height, layoutSize.height);
        
        self.contentSize = contentSize;
        
        // Now, clamp the content offset. This can get out of bounds if we are scrolled way to the end in portait mode and flip to landscape.
        
        //        NSLog(@"self.bounds = %@", NSStringFromCGRect(bounds));
        //        NSLog(@"self.contentSize = %@", NSStringFromCGSize(contentSize));
        //        NSLog(@"self.contentOffset = %@", NSStringFromCGPoint(self.contentOffset));
        
        CGPoint contentOffset = self.contentOffset;
        CGPoint clampedContentOffset = _clampContentOffset(self, contentOffset);
        if (!CGPointEqualToPoint(contentOffset, clampedContentOffset))
            self.contentOffset = contentOffset; // Don't reset if it is the same, or this'll kill off any bounce animation
        
        contentRect.origin = contentOffset;
        contentRect.size = bounds.size;
        DEBUG_LAYOUT(@"contentRect = %@", NSStringFromCGRect(contentRect));
    }
    
    return (LayoutInfo){
        .topControlsHeight = topControlsHeight,
        .contentRect = contentRect,
        .itemSize = itemSize,
        .itemsPerRow = itemsPerRow
    };
}

- (void)layoutSubviews;
{
    LayoutInfo layoutInfo = _updateLayout(self);
    CGSize itemSize = layoutInfo.itemSize;
    CGRect contentRect = layoutInfo.contentRect;
    
    if (itemSize.width <= 0 || itemSize.height <= 0) {
        // We aren't sized right yet
        DEBUG_LAYOUT(@"  Bailing since we have zero size");
        return;
    }
    
    [_renameSession layoutDimmingView];
    
    if (_topControls) {
        CGRect frame = _topControls.frame;
        frame.origin.x = (CGRectGetWidth(contentRect) / 2) - (frame.size.width / 2);
        frame.origin.y = (CGRectGetHeight(_topControls.frame) / 2) - (frame.size.height / 2);
        frame = CGRectIntegral(frame);
        _topControls.frame = frame;
        
        if ([_topControls superview] != self)
            [self addSubview:_topControls];

        // Scroll past the top controls if they are visible and we are supposed to (coming on screen).
        if (_shouldHideTopControlsOnNextLayout) {
            _shouldHideTopControlsOnNextLayout = NO;

            UIEdgeInsets contentInset = self.contentInset;
            CGPoint offset = self.contentOffset;
            offset.y = (layoutInfo.topControlsHeight - contentInset.top);
            
            if (offset.y > self.contentOffset.y) {
                self.contentOffset = offset;
            }
        }
    }

    // Expand the visible content rect to preload nearby previews
    CGRect previewLoadingRect = CGRectInset(contentRect, 0, -contentRect.size.height);
    
    // We don't need this for the scroller and calling it causes our item views to layout their contents out before we've adjusted their frames (and we don't even want to layout the hidden views).
    // [super layoutSubviews];
    
    // The newly created views need to get laid out the first time w/o animation on.
    OUIWithAnimationsDisabled(_flags.isAnimatingRotationChange, ^{
        // Keep track of which item views are in use by visible items
        NSMutableArray *unusedFileItemViews = [[NSMutableArray alloc] initWithArray:_fileItemViews];
        NSMutableArray *unusedGroupItemViews = [[NSMutableArray alloc] initWithArray:_groupItemViews];
        
        // Keep track of items that don't have views that need them.
        NSMutableArray *visibleItemsWithoutView = nil;
        NSUInteger positionIndex = 0;
        
        NSMutableDictionary *previousFileItemToPreview = [[NSMutableDictionary alloc] initWithDictionary:_fileItemToPreview];
        NSMutableDictionary *updatedFileItemToPreview = [[NSMutableDictionary alloc] init];
        
        // Build a item->view mapping once; calling -itemViewForItem: is too slow w/in this loop since -layoutSubviews is called very frequently.
        NSMutableDictionary *itemToView = [[NSMutableDictionary alloc] init];
        {
            for (OUIDocumentPickerFileItemView *itemView in _fileItemViews) {
                ODSFileItem *fileItem = (ODSFileItem *)itemView.item;
                if (fileItem)
                    [itemToView setObject:itemView forKey:fileItem];
            }
            
            for (OUIDocumentPickerGroupItemView *itemView in _groupItemViews) {
                ODSFolderItem *groupItem = (ODSFolderItem *)itemView.item;
                if (groupItem)
                    [itemToView setObject:itemView forKey:groupItem];
            }
        }
        
        for (ODSItem *item in _sortedItems) {        
            // Calculate the frame we would use for each item.
            DEBUG_LAYOUT(@"item (%ld,%ld) %@", row, column, [item shortDescription]);
            
            CGRect frame = _frameForPositionAtIndex(positionIndex, layoutInfo);
            
            // If the item is on screen, give it a view to use
            BOOL itemVisible = CGRectIntersectsRect(frame, contentRect);
            
            BOOL shouldLoadPreview = CGRectIntersectsRect(frame, previewLoadingRect);
            if ([item isKindOfClass:[ODSFileItem class]]) {
                ODSFileItem *fileItem = (ODSFileItem *)item;
                OUIDocumentPreview *preview = [previousFileItemToPreview objectForKey:fileItem];
                
                if (shouldLoadPreview) {
                    if (!preview) {
                        Class documentClass = [[OUIDocumentAppController controller] documentClassForURL:fileItem.fileURL];
                        preview = [OUIDocumentPreview makePreviewForDocumentClass:documentClass fileURL:fileItem.fileURL date:fileItem.fileModificationDate withArea:OUIDocumentPreviewAreaLarge];
                        [preview incrementDisplayCount];
                    }
                    [updatedFileItemToPreview setObject:preview forKey:fileItem];
                } else {
                    if (preview)
                        [preview decrementDisplayCount];
                }
                
                [previousFileItemToPreview removeObjectForKey:fileItem];
            } else if ([item isKindOfClass:[ODSFolderItem class]]) {
                if (shouldLoadPreview) {
                    OUIDocumentPickerItemView *itemView = [self itemViewForItem:item];
                    [itemView loadPreviews];
                }
            }
            
            DEBUG_LAYOUT(@"  assigned frame %@, visible %d", NSStringFromCGRect(frame), itemVisible);
            
            if (itemVisible) {
                OUIDocumentPickerItemView *itemView = [itemToView objectForKey:item];

                // If it is visible and already has a view, let it keep the one it has.
                if (itemView) {
                    OBASSERT([unusedFileItemViews containsObjectIdenticalTo:itemView] ^ [unusedGroupItemViews containsObjectIdenticalTo:itemView]);
                    [unusedFileItemViews removeObjectIdenticalTo:itemView];
                    [unusedGroupItemViews removeObjectIdenticalTo:itemView];
                    itemView.frame = frame;
                    DEBUG_LAYOUT(@"  kept view %@", [itemView shortDescription]);
                } else {
                    // This item needs a view!
                    if (!visibleItemsWithoutView)
                        visibleItemsWithoutView = [NSMutableArray array];
                    [visibleItemsWithoutView addObject:item];
                }
            }
            
            if (!([_itemsIgnoredForLayout containsObject:item])) {
                positionIndex++;
            }
        }
        
        
        _fileItemToPreview = [updatedFileItemToPreview copy];
        
        [previousFileItemToPreview enumerateKeysAndObjectsUsingBlock:^(ODSFileItem *fileItem, OUIDocumentPreview *preview, BOOL *stop) {
            [preview decrementDisplayCount];
        }];
        
        // Now, assign views to visibile or nearly visible items that don't have them. First, union the two lists.
        for (ODSItem *item in visibleItemsWithoutView) {            
            
            NSMutableArray *itemViews = nil;
            if ([item isKindOfClass:[ODSFileItem class]]) {
                itemViews = unusedFileItemViews;
            } else {
                itemViews = unusedGroupItemViews;
            }
            OUIDocumentPickerItemView *itemView = [itemViews lastObject];
            
            if (itemView) {
                OBASSERT(itemView.superview == self); // we keep these views as subviews, just hide them.
                
                // Make the view start out at the "original" position instead of flying from where ever it was last left.
                [UIView performWithoutAnimation:^{
                    itemView.hidden = NO;
                    itemView.frame = [self frameForItem:item];
                    itemView.shrunken = ([_itemsBeingAdded member:item] != nil);
                    [itemView setEditing:_flags.isEditing animated:NO];
                    itemView.item = item;
                }];
                
                if ([self.delegate respondsToSelector:@selector(documentPickerScrollView:willDisplayItemView:)])
                    [self.delegate documentPickerScrollView:self willDisplayItemView:itemView];

                [itemViews removeLastObject];
                DEBUG_LAYOUT(@"Assigned view %@ to item %@", [itemView shortDescription], item.name);
            } else {
                DEBUG_LAYOUT(@"Missing view for item %@ at %@", item.name, NSStringFromCGRect([self frameForItem:item]));
                OBASSERT(itemView); // we should never run out given that we make enough up front
            }
        }
        
        // Update dragging state
        for (OUIDocumentPickerFileItemView *fileItemView in _fileItemViews) {
            if (fileItemView.hidden) {
                fileItemView.draggingState = OUIDocumentPickerItemViewNoneDraggingState;
                continue;
            }
            
            ODSFileItem *fileItem = (ODSFileItem *)fileItemView.item;
            OBASSERT([fileItem isKindOfClass:[ODSFileItem class]]);
            
            OBASSERT(!fileItem.draggingSource || fileItem != _draggingDestinationItem); // can't be both the source and destination of a drag!
            
            if (fileItem == _draggingDestinationItem)
                fileItemView.draggingState = OUIDocumentPickerItemViewDestinationDraggingState;
            else if (fileItem.draggingSource)
                fileItemView.draggingState = OUIDocumentPickerItemViewSourceDraggingState;
            else
                fileItemView.draggingState = OUIDocumentPickerItemViewNoneDraggingState;        
        }
        
        // Any remaining unused item views should have no item and be hidden.
        for (OUIDocumentPickerFileItemView *view in unusedFileItemViews) {
            view.hidden = YES;
            [view prepareForReuse];
            if ([self.delegate respondsToSelector:@selector(documentPickerScrollView:willEndDisplayingItemView:)])
                [self.delegate documentPickerScrollView:self willEndDisplayingItemView:view];
            
        }
        for (OUIDocumentPickerGroupItemView *view in unusedGroupItemViews) {
            view.hidden = YES;
            [view prepareForReuse];
            if ([self.delegate respondsToSelector:@selector(documentPickerScrollView:willEndDisplayingItemView:)])
                [self.delegate documentPickerScrollView:self willEndDisplayingItemView:view];
        }
    });
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer;
{
    if (gestureRecognizer == _startDragRecognizer) {
        if (_startDragRecognizer.wasATap)
            return NO;
        
        // Only start editing and float up a preview if we hit a file preview
        return ([self itemViewHitByRecognizer:_startDragRecognizer] != nil);
    }
    
    return YES;
}

#pragma mark - NSObject (OUIDocumentPickerItemMetadataView)

- (void)documentPickerItemNameStartedEditing:(id)sender;
{
    UIView *view = sender; // This is currently the private name+date view. Could hook this up better if this all works out (maybe making our item view publish a 'started editing' control event.
    OUIDocumentPickerItemView *itemView = [view containingViewOfClass:[OUIDocumentPickerItemView class]];
    
    // should be one of ours, not some other temporary animating item view
    OBASSERT([_fileItemViews containsObjectIdenticalTo:itemView] ^ [_groupItemViews containsObjectIdenticalTo:itemView]);

    [self.delegate documentPickerScrollView:self itemViewStartedEditingName:itemView];
}

- (void)documentPickerItemNameEndedEditing:(id)sender withName:(NSString *)name;
{
    UIView *view = sender; // This is currently the private name+date view. Could hook this up better if this all works out (maybe making our item view publish a 'started editing' control event.
    OUIDocumentPickerItemView *itemView = [view containingViewOfClass:[OUIDocumentPickerItemView class]];
    
    // should be one of ours, not some other temporary animating item view
    OBASSERT([_fileItemViews containsObjectIdenticalTo:itemView] ^ [_groupItemViews containsObjectIdenticalTo:itemView]);
    
    [self.delegate documentPickerScrollView:self itemView:itemView finishedEditingName:(NSString *)name];
}

#pragma mark - Private

- (void)_itemViewTapped:(OUIDocumentPickerItemView *)itemView;
{
    // should be one of ours, not some other temporary animating item view
    OBASSERT([_fileItemViews containsObjectIdenticalTo:itemView] ^ [_groupItemViews containsObjectIdenticalTo:itemView]);
        
    [self.delegate documentPickerScrollView:self itemViewTapped:itemView];
}

// The size of the document prevew grid in items. That is, if gridSize.width = 4, then 4 items will be shown across the width.
// The width must be at least one and integral. The height must be at least one, but may be non-integral if you want to have a row of itemss peeking out.
- (CGSize)_gridSize;
{
    CGSize layoutSize = self.bounds.size;
    if (layoutSize.width <= 0 || layoutSize.height <= 0)
        return CGSizeMake(1,1); // placeholder because layoutSize not set yet

    // Adding a single kItemHorizontalPadding here because we want to compute the space for itemWidth*nItems + padding*(nItems-1), moving padding*1 to the other side of the equation simplifies everything else
    layoutSize.width += kItemHorizontalPadding;
    
    CGFloat itemWidth = kItemNormalSize;
    CGFloat itemsAcross = floor(layoutSize.width / (itemWidth + kItemHorizontalPadding));
    CGFloat rotatedItemsAcross = floor(layoutSize.height / (itemWidth + kItemHorizontalPadding));

    if (itemsAcross < 2 || rotatedItemsAcross < 2) {
        itemWidth = kItemSmallSize;
        itemsAcross = floor(layoutSize.width / (itemWidth + kItemHorizontalPadding));
    }
    return CGSizeMake(itemsAcross, layoutSize.height / (itemWidth + kItemVerticalPadding));
}

- (void)_startDragRecognizer:(OUIDragGestureRecognizer *)recognizer;
{
    OBPRECONDITION(recognizer == _startDragRecognizer);
    [self.delegate documentPickerScrollView:self dragWithRecognizer:_startDragRecognizer];
}

@end