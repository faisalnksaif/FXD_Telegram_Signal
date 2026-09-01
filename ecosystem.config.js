module.exports = {
	apps: [
		{
			name: "telegram-fxd-vip",
			script: "dist/listener.js",
			cwd: __dirname,
			instances: 1,
			exec_mode: "fork",
			autorestart: true,
			watch: false,
			max_restarts: 10,
			env: {
				NODE_ENV: "production",
			},
		},
	],
};
