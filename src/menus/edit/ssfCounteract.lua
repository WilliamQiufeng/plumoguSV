function ssfCounteractMenu()
    local menuVars = getMenuVars('ssfCounteract')
    _, menuVars.tolerance = imgui.InputFloat('Tolerance (msx)', menuVars.tolerance, 0, 0, '%.3f')
    HelpMarker('Maximum visible head-position error from the first selected start time until each note starts.')
    cache.save('ssfCounteractMenu', menuVars)
    simpleActionMenu('Counteract SSF for selected notes', 2, ssfCounteract, menuVars)
end
