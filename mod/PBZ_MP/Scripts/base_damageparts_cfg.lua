-- Local diagnostic proposal only; no gameplay or network configuration is changed.
return {
    version = 1,
    mode = 'observe',
    moves = { GA_BrutalAxe_Normal_C = true, GA_BrutalAxe_Sprint_C = true },
    multipliers = { ordinary = 4.1, charge = 3.05, shock = 1.2, sprint = 0.5 },
    assets = {
        BD_Hun_BrutalAxe_Release_01_01 = { part = 'ordinary', branch = 'unverified' },
        BD_Hun_BrutalAxe_Release_02_01 = { part = 'charge', branch = 'unverified' },
        BD_Hun_BrutalAxe_Release_02_02 = { part = 'charge', branch = 'unverified' },
        BD_Hun_BrutalAxe_Release_02_Shock = { part = 'shock', branch = 'asset' },
        BD_Hun_BrutalAxe_Release_03_01 = { part = 'charge', branch = 'Charge3' },
        BD_Hun_BrutalAxe_Release_03_02 = { part = 'charge', branch = 'unverified' },
        BD_Hun_BrutalAxe_Release_03_03 = { part = 'charge', branch = 'unverified' },
        BD_Hun_BrutalAxe_Release_03_Shock_01 = { part = 'shock', branch = 'Charge3' },
        BD_Hun_BrutalAxe_Release_03_Shock_02 = { part = 'shock', branch = 'Charge3' },
        BD_Hun_BrutalAxe_SprintRelease_01 = { part = 'sprint', branch = 'asset' },
        BD_Hun_BrutalAxe_SprintRelease_02 = { part = 'sprint', branch = 'SprintRelease2' },
        BD_Hun_BrutalAxe_SprintRelease_02_Shock = { part = 'sprint', branch = 'SprintRelease2' },
    },
}
