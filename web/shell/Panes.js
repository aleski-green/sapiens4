// Browser geometry and platform events. Layout decisions are in Panes.purs.
export const metrics = () => ({touch:window.matchMedia?.('(pointer: coarse)').matches === true,
  width:window.innerWidth,height:window.innerHeight,orientation:window.screen.orientation?.type,
  visual:window.visualViewport ? {scale:window.visualViewport.scale,height:window.visualViewport.height} : null});
export const onOrientation = action => () => { window.screen.orientation?.addEventListener('change', action); };
export const onViewport = action => () => { window.visualViewport?.addEventListener('resize', action); };
export const layout = element => () => ({visible:element.getClientRects().length > 0,scrollHeight:element.scrollHeight});
